#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
qmp-proxy.py - QMP fanout proxy for QEMU.

QEMU's `-qmp unix:...,server=on` accepts ONE client at a time.  When dgame
holds it, image-search / your QMP scripts get ECONNREFUSED.  This proxy:

  1. Connects upstream as the lone QMP client (claims the slot).
  2. Performs `qmp_capabilities` once, on behalf of everyone downstream.
  3. Listens on a sibling Unix socket and accepts N concurrent clients.
  4. Per request rewrites the `id` field so responses route back to the
     originator; events are broadcast to every connected client; OOB
     commands (`exec-oob`) pass through unchanged.

Usage:

    # shortcut - derive both paths from a VM instance number
    qmp-proxy.py 2
    # upstream  : /tmp/qemu-stealth-2.qmp        (the QEMU side)
    # listen    : /tmp/qemu-stealth-2.qmp.proxy  (point your tools here)

    # explicit
    qmp-proxy.py --upstream /run/qemu/vm1.qmp \\
                 --listen   /run/qemu/vm1.qmp.proxy

Once running, point dgame, image-search, ad-hoc `socat` etc. at the
`.qmp.proxy` path; they all coexist.

Caveats:

  * Fan-out is one process - if you run two proxies against the same
    upstream they fight for the slot.  Single proxy per VM.
  * Commands are still serialised upstream (QMP itself is a single
    pipe).  Two clients firing `query-status` simultaneously get
    sequential, correct responses; nothing interleaves on the wire.
  * If upstream QEMU dies, every client receives a synthesised
    `PROXY_UPSTREAM_LOST` event then gets disconnected and the proxy
    exits.  Restart after QEMU comes back.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
import time
from pathlib import Path

LOG = logging.getLogger('qmp-proxy')


class QmpProxy:
    def __init__(self, upstream_path: str, listen_path: str,
                 wait_upstream_secs: float = 0.0):
        self.upstream_path = upstream_path
        self.listen_path = listen_path
        self.wait_upstream_secs = wait_upstream_secs
        self.upstream_reader: asyncio.StreamReader | None = None
        self.upstream_writer: asyncio.StreamWriter | None = None
        self.upstream_greeting: dict | None = None
        self.upstream_lock = asyncio.Lock()
        self.clients: dict[int, dict] = {}
        self.pending: dict[str, tuple[int, object | None]] = {}
        self.next_cid = 1
        self.next_pid = 1
        self.shutting_down = False

    # --- upstream side ------------------------------------------------

    async def connect_upstream(self) -> None:
        LOG.info('connecting upstream %s', self.upstream_path)
        # Retry the initial connect when the user explicitly asked us to wait
        # (e.g. start-vm.sh races us against QEMU's own listen()).  Without
        # --wait-upstream we keep the historical "fail fast" behaviour so a
        # plain misconfiguration still surfaces immediately.
        deadline = (time.monotonic() + self.wait_upstream_secs
                    if self.wait_upstream_secs > 0 else None)
        first_attempt = True
        while True:
            try:
                self.upstream_reader, self.upstream_writer = \
                    await asyncio.open_unix_connection(self.upstream_path)
                break
            except (FileNotFoundError, ConnectionRefusedError) as e:
                if deadline is None or time.monotonic() >= deadline:
                    raise
                if first_attempt:
                    LOG.info('upstream not ready (%s); retrying for %.1fs',
                             type(e).__name__, self.wait_upstream_secs)
                    first_attempt = False
                await asyncio.sleep(0.2)
        line = await self.upstream_reader.readline()
        if not line:
            raise RuntimeError('upstream closed before greeting')
        try:
            self.upstream_greeting = json.loads(line)
        except Exception as e:
            raise RuntimeError(f'bad upstream greeting: {line!r}: {e}')
        if 'QMP' not in self.upstream_greeting:
            raise RuntimeError(f'unexpected greeting: {self.upstream_greeting}')

        await self._send_upstream({'execute': 'qmp_capabilities'})
        ack_line = await self.upstream_reader.readline()
        try:
            ack = json.loads(ack_line)
        except Exception as e:
            raise RuntimeError(f'bad cap ack: {ack_line!r}: {e}')
        if 'return' not in ack:
            raise RuntimeError(f'qmp_capabilities failed: {ack}')
        ver = self.upstream_greeting['QMP'].get('version', {}).get('qemu', {})
        LOG.info('upstream negotiated, qemu=%s', ver)

    async def _send_upstream(self, msg: dict) -> None:
        line = (json.dumps(msg, separators=(',', ':')) + '\n').encode()
        async with self.upstream_lock:
            self.upstream_writer.write(line)
            await self.upstream_writer.drain()

    async def upstream_loop(self) -> None:
        try:
            while not self.shutting_down:
                line = await self.upstream_reader.readline()
                if not line:
                    LOG.warning('upstream EOF')
                    break
                try:
                    msg = json.loads(line)
                except Exception:
                    LOG.warning('upstream non-JSON: %r', line[:200])
                    continue
                await self._dispatch_upstream(line, msg)
        finally:
            await self._notify_upstream_lost()

    async def _dispatch_upstream(self, raw: bytes, msg: dict) -> None:
        if 'event' in msg:
            await self._broadcast(raw)
            return
        if 'return' in msg or 'error' in msg:
            pid = msg.get('id')
            if isinstance(pid, str) and pid in self.pending:
                cid, user_id = self.pending.pop(pid)
                if user_id is None:
                    msg.pop('id', None)
                else:
                    msg['id'] = user_id
                await self._send_to_client(
                    cid, json.dumps(msg, separators=(',', ':')) + '\n')
            else:
                LOG.warning('orphan response id=%r, broadcasting', pid)
                await self._broadcast(raw)
            return
        # Anything else (shouldn't happen) - broadcast as fallback.
        await self._broadcast(raw)

    # --- downstream side ----------------------------------------------

    async def handle_client(self, reader: asyncio.StreamReader,
                            writer: asyncio.StreamWriter) -> None:
        cid = self.next_cid
        self.next_cid += 1
        self.clients[cid] = {
            'writer': writer,
            'negotiated': False,
        }
        LOG.info('client %d connected', cid)
        try:
            greet = (json.dumps(self.upstream_greeting) + '\n').encode()
            writer.write(greet)
            await writer.drain()
            await self._client_loop(cid, reader, writer)
        except (ConnectionResetError, BrokenPipeError):
            pass
        except Exception as e:
            LOG.warning('client %d error: %s', cid, e)
        finally:
            self.clients.pop(cid, None)
            # drop any pending responses queued for this client
            for pid, (owner, _user) in list(self.pending.items()):
                if owner == cid:
                    self.pending.pop(pid, None)
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass
            LOG.info('client %d gone', cid)

    async def _client_loop(self, cid: int, reader: asyncio.StreamReader,
                           writer: asyncio.StreamWriter) -> None:
        cli = self.clients[cid]
        while not self.shutting_down:
            line = await reader.readline()
            if not line:
                return
            try:
                msg = json.loads(line)
            except Exception:
                err = {'error': {'class': 'GenericError',
                                 'desc': 'invalid JSON'}}
                writer.write((json.dumps(err) + '\n').encode())
                await writer.drain()
                continue

            cmd = msg.get('execute') or msg.get('exec-oob')

            # qmp_capabilities: per-client local handshake (don't forward).
            if cmd == 'qmp_capabilities' and not cli['negotiated']:
                cli['negotiated'] = True
                ack = {'return': {}}
                if 'id' in msg:
                    ack['id'] = msg['id']
                writer.write((json.dumps(ack) + '\n').encode())
                await writer.drain()
                continue

            # Rewrite id, forward upstream.
            user_id = msg.pop('id', None)
            pid = f'p{self.next_pid}'
            self.next_pid += 1
            msg['id'] = pid
            self.pending[pid] = (cid, user_id)

            try:
                await self._send_upstream(msg)
            except Exception as e:
                self.pending.pop(pid, None)
                err = {'error': {'class': 'GenericError',
                                 'desc': f'upstream send failed: {e}'}}
                if user_id is not None:
                    err['id'] = user_id
                writer.write((json.dumps(err) + '\n').encode())
                await writer.drain()
                return

    async def _send_to_client(self, cid: int, payload: str) -> None:
        cli = self.clients.get(cid)
        if not cli:
            return
        try:
            cli['writer'].write(payload.encode())
            await cli['writer'].drain()
        except (ConnectionResetError, BrokenPipeError):
            pass

    async def _broadcast(self, line: bytes) -> None:
        for cid in list(self.clients.keys()):
            cli = self.clients.get(cid)
            if not cli:
                continue
            try:
                cli['writer'].write(line)
                await cli['writer'].drain()
            except (ConnectionResetError, BrokenPipeError):
                pass

    async def _notify_upstream_lost(self) -> None:
        msg = {
            'event': 'PROXY_UPSTREAM_LOST',
            'data': {},
            'timestamp': {'seconds': 0, 'microseconds': 0},
        }
        line = (json.dumps(msg) + '\n').encode()
        await self._broadcast(line)

    # --- lifecycle ----------------------------------------------------

    async def run(self) -> None:
        await self.connect_upstream()
        if os.path.exists(self.listen_path):
            os.unlink(self.listen_path)
        Path(self.listen_path).parent.mkdir(parents=True, exist_ok=True)
        server = await asyncio.start_unix_server(
            self.handle_client, path=self.listen_path)
        os.chmod(self.listen_path, 0o660)
        LOG.info('proxy listening %s -> %s',
                 self.listen_path, self.upstream_path)

        upstream_task = asyncio.create_task(self.upstream_loop())
        try:
            async with server:
                serve_task = asyncio.create_task(server.serve_forever())
                done, pending = await asyncio.wait(
                    [upstream_task, serve_task],
                    return_when=asyncio.FIRST_COMPLETED)
                for t in pending:
                    t.cancel()
        finally:
            self.shutting_down = True
            try:
                self.upstream_writer.close()
                await self.upstream_writer.wait_closed()
            except Exception:
                pass
            try:
                os.unlink(self.listen_path)
            except OSError:
                pass


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('instance', nargs='?', type=int,
                   help='derive paths from VM instance number '
                        '(/tmp/qemu-stealth-N.qmp[.proxy])')
    p.add_argument('--upstream',
                   help='QEMU QMP socket (the single-slot one)')
    p.add_argument('--listen',
                   help='proxy listen path (multi-client)')
    p.add_argument('--wait-upstream', type=float, default=0.0, metavar='SECS',
                   help='retry connecting upstream for up to SECS seconds '
                        '(default 0 = fail fast); use this when racing the '
                        'QEMU launcher (start-vm.sh --proxy passes 30)')
    p.add_argument('--verbose', '-v', action='store_true')
    args = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='%(asctime)s %(levelname)s %(message)s',
        datefmt='%H:%M:%S')

    if args.instance is not None:
        upstream = args.upstream or f'/tmp/qemu-stealth-{args.instance}.qmp'
        listen = args.listen or f'/tmp/qemu-stealth-{args.instance}.qmp.proxy'
    else:
        if not args.upstream or not args.listen:
            sys.exit('need <instance> or --upstream + --listen')
        upstream = args.upstream
        listen = args.listen

    if args.wait_upstream <= 0 and not os.path.exists(upstream):
        sys.exit(f'upstream {upstream} does not exist - is QEMU running? '
                 '(use --wait-upstream <secs> to retry while QEMU starts)')

    proxy = QmpProxy(upstream, listen, wait_upstream_secs=args.wait_upstream)

    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)

    def stop_now():
        proxy.shutting_down = True
        for t in asyncio.all_tasks(loop):
            t.cancel()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_now)

    try:
        loop.run_until_complete(proxy.run())
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass
    except Exception as e:
        LOG.error('fatal: %s', e)
        return 1
    finally:
        loop.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
