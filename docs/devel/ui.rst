=================
QEMU UI subsystem
=================

QEMU Clipboard
--------------

.. kernel-doc:: include/ui/clipboard.h

Guest hardware cursor position
------------------------------

The QMP command ``query-guest-mouse-position`` reports the latest
hardware cursor position that the guest display device has reported to
QEMU.  The command is host-side only: it reads the state cached in the
``QemuGraphicConsole`` and does not create any new guest-visible device,
register, or guest agent command.

Display devices update this state through ``dpy_mouse_set()``.  GL based
display paths update the same cached state through
``dpy_gl_cursor_position()`` and ``dpy_gl_cursor_dmabuf()`` so QMP
clients see the same position and visibility that display frontends use.

The returned ``valid`` field must be checked before using ``x`` and
``y``.  When ``valid`` is false, QEMU has not yet seen a hardware cursor
position update from the guest and the coordinates are placeholders.
Software cursors drawn directly into the guest framebuffer are not
observable through this interface.
