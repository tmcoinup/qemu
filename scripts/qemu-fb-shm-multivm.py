#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
qemu-fb-shm-multivm.py - orchestrator for fan-out streaming of N VMs.

Each VM has its own QEMU process started with `-display fb-shm,id=vmN,...`.
This script fans out one consumer per VM, pinning each consumer to its own
CPU core slice and assigning a unique encoder session.

Hardware budget cheat sheet on a single host:

    | Encoder        | Sessions per chip (typical)              |
    | -------------- | ---------------------------------------- |
    | NVENC (GA10x+) | unlimited (consumer cards: 5 unless      |
    |                | nvidia-patch is applied)                  |
    | NVENC (Pascal) | 2                                        |
    | QSV (Intel)    | ~16, all share a single ring             |
    | AMF (AMD)      | ~16, similar single-ring                 |
    | x264 (CPU)     | 1 core per ~1080p30; scale with cores    |

Example config file (YAML-ish, parsed below):

    vms:
      - id: vm1
        sock: /run/qemu/fb-vm1.sock
        output: rtmp://ingest/live/vm1
        encoder: h264_nvenc
        cpus: "0-3"
        roi: "0,0,1920,1080"
      - id: vm2
        sock: /run/qemu/fb-vm2.sock
        output: udp://127.0.0.1:5002?pkt_size=1316
        encoder: h264_nvenc
        cpus: "4-7"

This script does NOT spawn QEMU itself — that is the user's responsibility
(see qemu-fb-shm-spawn.sh for an example).  It only attaches consumers to
already-running fb-shm sockets and supervises them.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path

LOG = logging.getLogger('multivm')

CONSUMER = Path(__file__).resolve().parent / 'qemu-fb-shm-stream.py'


def parse_cpu_list(spec: str) -> list:
    """Accepts '0-3', '0,2,4', '0-3,7' etc."""
    out = []
    for part in spec.split(','):
        part = part.strip()
        if '-' in part:
            a, b = part.split('-', 1)
            out.extend(range(int(a), int(b) + 1))
        else:
            out.append(int(part))
    return sorted(set(out))


def load_config(path: str) -> dict:
    if path.endswith(('.yaml', '.yml')):
        try:
            import yaml
            with open(path) as f:
                return yaml.safe_load(f)
        except ImportError:
            sys.exit('PyYAML required for YAML configs; pip install pyyaml '
                     'or use --config-json')
    with open(path) as f:
        return json.load(f)


def spawn_consumer(spec: dict, log_dir: Path) -> subprocess.Popen:
    cmd = ['python3', str(CONSUMER),
           '--sock',   spec['sock'],
           '--output', spec['output']]
    for opt in ('encoder', 'preset', 'bitrate', 'gop', 'rate', 'roi',
                'container', 'ffmpeg-extra'):
        if opt in spec:
            cmd += [f'--{opt}', str(spec[opt])]
    if 'cpus' in spec:
        cmd += ['--cpu-affinity', ','.join(map(str, parse_cpu_list(spec['cpus'])))]
    log_path = log_dir / f"{spec['id']}.log"
    log_f = open(log_path, 'ab')
    LOG.info('start vm=%s -> %s [log=%s]', spec['id'], spec['output'], log_path)
    return subprocess.Popen(cmd, stdout=log_f, stderr=subprocess.STDOUT,
                            preexec_fn=os.setpgrp)


def supervise(specs: list, log_dir: Path, restart: bool) -> int:
    procs: dict[str, subprocess.Popen] = {}
    stop = False
    def _sig(*_):
        nonlocal stop; stop = True
    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)
    for s in specs:
        procs[s['id']] = spawn_consumer(s, log_dir)
    try:
        while not stop:
            time.sleep(1.0)
            for s in specs:
                p = procs[s['id']]
                rc = p.poll()
                if rc is None:
                    continue
                LOG.warning('vm=%s consumer exited rc=%s', s['id'], rc)
                if restart and not stop:
                    time.sleep(1.0)
                    procs[s['id']] = spawn_consumer(s, log_dir)
    finally:
        LOG.info('shutting down')
        for pid, p in procs.items():
            if p.poll() is None:
                try:
                    os.killpg(os.getpgid(p.pid), signal.SIGTERM)
                except ProcessLookupError:
                    pass
        time.sleep(0.5)
        for pid, p in procs.items():
            if p.poll() is None:
                try:
                    os.killpg(os.getpgid(p.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--config', help='YAML or JSON config with `vms:` list')
    p.add_argument('--config-json', help='inline JSON config')
    p.add_argument('--log-dir', default='/tmp/qemu-fb-shm-logs')
    p.add_argument('--no-restart', action='store_true',
                   help="don't restart consumers when they exit")
    p.add_argument('--verbose', '-v', action='store_true')
    args = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format='%(asctime)s %(levelname)s %(name)s %(message)s')

    if args.config:
        cfg = load_config(args.config)
    elif args.config_json:
        cfg = json.loads(args.config_json)
    else:
        sys.exit('need --config or --config-json')
    specs = cfg.get('vms') or []
    if not specs:
        sys.exit('no `vms` entries in config')

    log_dir = Path(args.log_dir); log_dir.mkdir(parents=True, exist_ok=True)
    return supervise(specs, log_dir, restart=not args.no_restart)


if __name__ == '__main__':
    sys.exit(main())
