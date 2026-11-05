#!/usr/bin/env python3
"""Regression tests for the smoke terminal screen model.

Reproduces CI run 41923796968: the macOS packaged TUI had recovered, but
OpenTUI's differential repaint split ``Message Veasel`` across changed-cell
runs so the raw stripped byte stream never contained it contiguously.
"""

import re
import unittest

from terminal_screen import TerminalScreen

ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def differential_repaint(row: int, col: int, before: str, after: str) -> bytes:
    """Emit only the changed-cell runs, like a differential renderer."""
    out = bytearray()
    run_start: int | None = None
    for index in range(max(len(before), len(after))):
        old = before[index] if index < len(before) else " "
        new = after[index] if index < len(after) else " "
        if old == new:
            run_start = None
            continue
        if run_start is None:
            out += f"\x1b[{row};{col + index}H".encode()
            run_start = index
        out += new.encode()
    return bytes(out)


class TerminalScreenTests(unittest.TestCase):
    def test_differential_repaint_recovers_composer_placeholder(self) -> None:
        restoring = "Restoring this session's queued turns…"
        recovered = "Message Veasel…  ·  / commands  ·  @ paths  ·  $ skills"
        status_before = "○ connecting…"
        status_after = "● connected  ·  listening for activity"
        stream = (
            b"\x1b[?1049h\x1b[2J"
            + b"\x1b[4;3H" + "Start with a question or describe a coding task.".encode()
            + b"\x1b[20;3H" + restoring.encode()
            + b"\x1b[24;3H" + status_before.encode()
        )
        screen = TerminalScreen(rows=24, cols=100)
        screen.feed(stream)
        self.assertIn(restoring, screen.text())
        self.assertNotIn("Message Veasel", screen.text())

        repaint = differential_repaint(20, 3, restoring, recovered)
        repaint += differential_repaint(24, 3, status_before, status_after)
        # The old raw-byte assertion cannot see the recovered placeholder:
        # unchanged cells are never re-emitted, exactly as in the CI capture.
        self.assertNotIn(b"Message Veasel", ANSI.sub(b"", stream + repaint))
        # Split the repaint mid-escape to prove incremental feeding is safe.
        screen.feed(repaint[:7])
        screen.feed(repaint[7:])
        self.assertIn("Message Veasel", screen.text())
        self.assertIn("listening for activity", screen.text())
        self.assertNotIn("Restoring this session", screen.text())

    def test_cursor_erase_and_carriage_return(self) -> None:
        screen = TerminalScreen(rows=4, cols=20)
        screen.feed(b"\x1b[2;1Hhello world\rbye\x1b[K")
        self.assertIn("bye", screen.text())
        self.assertNotIn("world", screen.text())
        screen.feed(b"\x1b[2J\x1b[Hfresh")
        self.assertNotIn("bye", screen.text())
        self.assertIn("fresh", screen.text())

    def test_wraps_and_scrolls(self) -> None:
        screen = TerminalScreen(rows=2, cols=5)
        screen.feed("abcdefghijklmno".encode())
        # Three 5-cell lines in a 2-row screen scroll to the last two.
        self.assertEqual(screen.text().split("\n"), ["fghij", "klmno"])

    def test_osc_and_sgr_do_not_leak_text(self) -> None:
        screen = TerminalScreen(rows=2, cols=40)
        screen.feed(b"\x1b]8;;https://example.invalid\x07\x1b[1;31mred\x1b[0m plain")
        self.assertIn("red plain", screen.text())
        self.assertNotIn("example", screen.text())


if __name__ == "__main__":
    unittest.main()
