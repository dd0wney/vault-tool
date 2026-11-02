#!/usr/bin/env python3
"""Run a command on a new terminal and exit with the status of that command.

vault new needs a terminal for the YubiKey PIN. The tests must see the same
conditions from an interactive shell, CI, or an agent with no terminal at all.
"""
import os
import pty
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: with_pty.py <command> [args...]", file=sys.stderr)
        return 2

    pid, terminal = pty.fork()
    if pid == 0:
        os.execvp(sys.argv[1], sys.argv[1:])

    while True:
        try:
            data = os.read(terminal, 65536)
        except OSError:
            # Linux reports EIO when the command closes its terminal.
            break
        if not data:
            break
        os.write(sys.stdout.fileno(), data)

    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
