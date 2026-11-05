#!/usr/bin/env python3
"""Minimal VT screen model for the packaged-TUI smokes.

OpenTUI repaints differentially: a frame transition only emits the cell runs
that changed. Concatenating the raw byte stream and stripping escape codes
therefore splits words that were partially unchanged between frames (the
macOS smoke captured ``Msage Veasel`` / ``lstening`` while the real screen
showed the recovered composer). This model tracks cursor position and cell
contents so smoke assertions run against what a user actually sees.
"""

from __future__ import annotations

import codecs
import unicodedata


def _char_width(char: str) -> int:
    if unicodedata.combining(char):
        return 0
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


class TerminalScreen:
    """Fixed-size screen fed incrementally with raw terminal bytes."""

    def __init__(self, rows: int = 24, cols: int = 100) -> None:
        self.rows = rows
        self.cols = cols
        self._cells: list[list[str]] = [[" "] * cols for _ in range(rows)]
        self._row = 0
        self._col = 0
        self._saved = (0, 0)
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        # Parser state persisted across feeds: "", "esc", "csi", "osc",
        # "esc_str" (DCS/APC/PM/SOS payload), or "charset".
        self._state = ""
        self._params = ""

    def feed(self, data: bytes) -> None:
        for char in self._decoder.decode(bytes(data)):
            self._consume(char)

    def text(self) -> str:
        return "\n".join("".join(row).rstrip() for row in self._cells)

    # -- parser -----------------------------------------------------------

    def _consume(self, char: str) -> None:
        if self._state == "esc":
            self._state = ""
            if char == "[":
                self._state = "csi"
                self._params = ""
            elif char == "]":
                self._state = "osc"
            elif char in "_PXM^":
                self._state = "esc_str"
            elif char in "()#%":
                self._state = "charset"
            elif char == "7":
                self._saved = (self._row, self._col)
            elif char == "8":
                self._row, self._col = self._saved
            elif char == "M":  # reverse index
                self._row = max(0, self._row - 1)
            elif char in "DE":
                self._newline()
                if char == "E":
                    self._col = 0
            elif char == "c":
                self._erase_screen(2)
                self._row = self._col = 0
            return
        if self._state == "osc":
            if char in ("\x07", "\x1b"):
                self._state = "esc" if char == "\x1b" else ""
            return
        if self._state == "esc_str":
            if char == "\x1b":
                self._state = "esc"
            return
        if self._state == "charset":
            self._state = ""
            return
        if self._state == "csi":
            if "@" <= char <= "~":
                self._csi(char)
                self._state = ""
            else:
                self._params += char
            return
        if char == "\x1b":
            self._state = "esc"
        elif char == "\r":
            self._col = 0
        elif char == "\n" or char == "\x0b" or char == "\x0c":
            self._newline()
        elif char == "\b":
            self._col = max(0, self._col - 1)
        elif char == "\t":
            self._col = min(self.cols - 1, (self._col // 8 + 1) * 8)
        elif char >= " ":
            self._put(char)

    # -- screen operations --------------------------------------------------

    def _newline(self) -> None:
        if self._row >= self.rows - 1:
            self._cells.pop(0)
            self._cells.append([" "] * self.cols)
        else:
            self._row += 1

    def _put(self, char: str) -> None:
        width = _char_width(char)
        if width == 0:
            return
        if self._col >= self.cols:
            self._col = 0
            self._newline()
        self._cells[self._row][self._col] = char
        if width == 2 and self._col + 1 < self.cols:
            self._cells[self._row][self._col + 1] = ""
        self._col += width

    def _erase_screen(self, mode: int) -> None:
        if mode == 0:
            self._erase_line(0)
            for row in range(self._row + 1, self.rows):
                self._cells[row] = [" "] * self.cols
        elif mode == 1:
            self._erase_line(1)
            for row in range(self._row):
                self._cells[row] = [" "] * self.cols
        else:
            self._cells = [[" "] * self.cols for _ in range(self.rows)]

    def _erase_line(self, mode: int) -> None:
        row = self._cells[self._row]
        if mode == 0:
            start, end = self._col, self.cols
        elif mode == 1:
            start, end = 0, self._col + 1
        else:
            start, end = 0, self.cols
        for col in range(start, end):
            row[col] = " "

    def _csi(self, final: str) -> None:
        raw = self._params
        private = raw.startswith("?")
        parts = [p for p in raw.lstrip("?><!").split(";")]

        def num(index: int, default: int) -> int:
            try:
                return int(parts[index]) if parts[index] else default
            except (IndexError, ValueError):
                return default

        if final in "Hf":
            self._row = min(self.rows - 1, max(0, num(0, 1) - 1))
            self._col = min(self.cols - 1, max(0, num(1, 1) - 1))
        elif final == "A":
            self._row = max(0, self._row - num(0, 1))
        elif final in "Be":
            self._row = min(self.rows - 1, self._row + num(0, 1))
        elif final in "Ca":
            self._col = min(self.cols - 1, self._col + num(0, 1))
        elif final == "D":
            self._col = max(0, self._col - num(0, 1))
        elif final == "E":
            self._row = min(self.rows - 1, self._row + num(0, 1))
            self._col = 0
        elif final == "F":
            self._row = max(0, self._row - num(0, 1))
            self._col = 0
        elif final in "G`":
            self._col = min(self.cols - 1, max(0, num(0, 1) - 1))
        elif final == "d":
            self._row = min(self.rows - 1, max(0, num(0, 1) - 1))
        elif final == "J":
            self._erase_screen(num(0, 0))
        elif final == "K":
            self._erase_line(num(0, 0))
        elif final == "L":
            for _ in range(num(0, 1)):
                self._cells.insert(self._row, [" "] * self.cols)
                self._cells.pop()
        elif final == "M":
            for _ in range(num(0, 1)):
                self._cells.pop(self._row)
                self._cells.append([" "] * self.cols)
        elif final == "P":
            row = self._cells[self._row]
            del row[self._col : self._col + num(0, 1)]
            row.extend([" "] * (self.cols - len(row)))
        elif final == "@":
            row = self._cells[self._row]
            for _ in range(num(0, 1)):
                row.insert(self._col, " ")
            del row[self.cols :]
        elif final == "X":
            for col in range(self._col, min(self.cols, self._col + num(0, 1))):
                self._cells[self._row][col] = " "
        elif final == "S":
            for _ in range(num(0, 1)):
                self._cells.pop(0)
                self._cells.append([" "] * self.cols)
        elif final == "T":
            for _ in range(num(0, 1)):
                self._cells.pop()
                self._cells.insert(0, [" "] * self.cols)
        elif final == "s":
            self._saved = (self._row, self._col)
        elif final == "u":
            if not private and not raw.startswith(">"):
                self._row, self._col = self._saved
        elif final in "hl" and private and "1049" in parts:
            # Alternate-screen switches restart from a blank frame.
            self._erase_screen(2)
            self._row = self._col = 0
        # SGR (m), modes, scroll regions (r), queries: no visible cell effect.
