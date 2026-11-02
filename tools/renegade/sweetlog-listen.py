#!/usr/bin/env python3
"""Persistent UDP console listener for the phone's sweet-usb-live-log (port 5140)."""
import socket, sys, signal

signal.signal(signal.SIGHUP, signal.SIG_IGN)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
s.bind(("0.0.0.0", 5140))
path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/opencode/console.log"
with open(path, "ab", buffering=0) as f:
    while True:
        data, _ = s.recvfrom(2048)
        f.write(data)
