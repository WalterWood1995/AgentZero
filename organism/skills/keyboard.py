#!/usr/bin/env python3
# skills/keyboard.py - the organism TYPES on the old PC's keyboard for itself.
#
# Injects keystrokes over UDP (the kernel's N command) straight into the key handler,
# exactly as if typed on the physical keyboard: the characters echo on the on-screen
# input line and a trailing Enter submits the line (e.g. "web example.com" to the chat/
# reader console). With screenshot.py the Agent can type, SEE the result, and retype if
# a packet dropped - a fully self-served keyboard. (Only chars the kernel's input path
# accepts; the German-QWERTZ physical mapping does not apply to injected bytes.)
#
# Usage:
#   python skills/keyboard.py [ip] "text to type" [--no-enter]
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from hw import HW


def type_text(ip, text, enter=True):
    hw = HW(ip)
    hw.type_keys(text, enter=enter)
    print("typed %r%s on the old PC" % (text, " + Enter" if enter else ""))


if __name__ == "__main__":
    a = sys.argv[1:]
    ip = a[0] if a and a[0].count(".") == 3 else "127.0.0.1"
    rest = [x for x in a if x != ip]
    enter = "--no-enter" not in rest
    rest = [x for x in rest if x != "--no-enter"]
    text = rest[0] if rest else "hello"
    type_text(ip, text, enter)
