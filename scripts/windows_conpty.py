"""Windows ConPTY driver for the standalone Veasel terminal smoke."""

from __future__ import annotations

import ctypes
import re
import time
from ctypes import wintypes
from pathlib import Path
from typing import Callable


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

HPCON = wintypes.HANDLE
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
EXTENDED_STARTUPINFO_PRESENT = 0x00080000
STARTF_USESTDHANDLES = 0x00000100
HANDLE_FLAG_INHERIT = 0x00000001


class Coord(ctypes.Structure):
    _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]


class SecurityAttributes(ctypes.Structure):
    _fields_ = [
        ("nLength", wintypes.DWORD),
        ("lpSecurityDescriptor", wintypes.LPVOID),
        ("bInheritHandle", wintypes.BOOL),
    ]


class StartupInfo(ctypes.Structure):
    _fields_ = [
        ("cb", wintypes.DWORD),
        ("lpReserved", wintypes.LPWSTR),
        ("lpDesktop", wintypes.LPWSTR),
        ("lpTitle", wintypes.LPWSTR),
        ("dwX", wintypes.DWORD),
        ("dwY", wintypes.DWORD),
        ("dwXSize", wintypes.DWORD),
        ("dwYSize", wintypes.DWORD),
        ("dwXCountChars", wintypes.DWORD),
        ("dwYCountChars", wintypes.DWORD),
        ("dwFillAttribute", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("wShowWindow", wintypes.WORD),
        ("cbReserved2", wintypes.WORD),
        ("lpReserved2", ctypes.POINTER(ctypes.c_ubyte)),
        ("hStdInput", wintypes.HANDLE),
        ("hStdOutput", wintypes.HANDLE),
        ("hStdError", wintypes.HANDLE),
    ]


class StartupInfoEx(ctypes.Structure):
    _fields_ = [("StartupInfo", StartupInfo), ("lpAttributeList", wintypes.LPVOID)]


class ProcessInformation(ctypes.Structure):
    _fields_ = [
        ("hProcess", wintypes.HANDLE),
        ("hThread", wintypes.HANDLE),
        ("dwProcessId", wintypes.DWORD),
        ("dwThreadId", wintypes.DWORD),
    ]


kernel32.CreatePipe.argtypes = [
    ctypes.POINTER(wintypes.HANDLE),
    ctypes.POINTER(wintypes.HANDLE),
    ctypes.POINTER(SecurityAttributes),
    wintypes.DWORD,
]
kernel32.CreatePipe.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL
kernel32.SetHandleInformation.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD]
kernel32.SetHandleInformation.restype = wintypes.BOOL
kernel32.CreatePseudoConsole.argtypes = [
    Coord,
    wintypes.HANDLE,
    wintypes.HANDLE,
    wintypes.DWORD,
    ctypes.POINTER(HPCON),
]
kernel32.CreatePseudoConsole.restype = ctypes.c_long
kernel32.ClosePseudoConsole.argtypes = [HPCON]
kernel32.PeekNamedPipe.argtypes = [
    wintypes.HANDLE,
    wintypes.LPVOID,
    wintypes.DWORD,
    wintypes.LPVOID,
    ctypes.POINTER(wintypes.DWORD),
    wintypes.LPVOID,
]
kernel32.PeekNamedPipe.restype = wintypes.BOOL
kernel32.ReadFile.argtypes = [
    wintypes.HANDLE,
    wintypes.LPVOID,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
    wintypes.LPVOID,
]
kernel32.ReadFile.restype = wintypes.BOOL
kernel32.WriteFile.argtypes = [
    wintypes.HANDLE,
    wintypes.LPCVOID,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
    wintypes.LPVOID,
]
kernel32.WriteFile.restype = wintypes.BOOL
kernel32.InitializeProcThreadAttributeList.argtypes = [
    wintypes.LPVOID,
    wintypes.DWORD,
    wintypes.DWORD,
    ctypes.POINTER(ctypes.c_size_t),
]
kernel32.InitializeProcThreadAttributeList.restype = wintypes.BOOL
kernel32.UpdateProcThreadAttribute.argtypes = [
    wintypes.LPVOID,
    wintypes.DWORD,
    ctypes.c_size_t,
    wintypes.LPVOID,
    ctypes.c_size_t,
    wintypes.LPVOID,
    wintypes.LPVOID,
]
kernel32.UpdateProcThreadAttribute.restype = wintypes.BOOL
kernel32.DeleteProcThreadAttributeList.argtypes = [wintypes.LPVOID]
kernel32.CreateProcessW.argtypes = [
    wintypes.LPCWSTR,
    wintypes.LPWSTR,
    wintypes.LPVOID,
    wintypes.LPVOID,
    wintypes.BOOL,
    wintypes.DWORD,
    wintypes.LPVOID,
    wintypes.LPCWSTR,
    ctypes.POINTER(StartupInfo),
    ctypes.POINTER(ProcessInformation),
]
kernel32.CreateProcessW.restype = wintypes.BOOL
kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
kernel32.GetExitCodeProcess.restype = wintypes.BOOL
kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
kernel32.WaitForSingleObject.restype = wintypes.DWORD
kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
kernel32.TerminateProcess.restype = wintypes.BOOL


def _winerror(operation: str) -> OSError:
    return ctypes.WinError(ctypes.get_last_error(), operation)


def run_tui_conpty(
    tui_path: Path,
    env: dict[str, str],
    session_title: str,
    session_id: str,
    wait_for_persisted_reply: Callable[[str, str], None],
) -> None:
    """Run a packaged TUI in ConPTY and verify a mock-provider conversation."""
    input_read = wintypes.HANDLE()
    input_write = wintypes.HANDLE()
    output_read = wintypes.HANDLE()
    output_write = wintypes.HANDLE()
    process = ProcessInformation()
    pseudoconsole = HPCON()
    attribute_storage = None
    attribute_list = wintypes.LPVOID()
    attribute_list_initialized = False
    output = bytearray()
    process_created = False
    child_stdin_read = wintypes.HANDLE()
    child_stdin_write = wintypes.HANDLE()

    def close(handle: wintypes.HANDLE | int) -> None:
        value = handle.value if isinstance(handle, wintypes.HANDLE) else handle
        if value:
            kernel32.CloseHandle(wintypes.HANDLE(value))
            if isinstance(handle, wintypes.HANDLE):
                handle.value = None

    def drain() -> None:
        available = wintypes.DWORD()
        if not kernel32.PeekNamedPipe(output_read, None, 0, None, ctypes.byref(available), None):
            error = ctypes.get_last_error()
            if error not in (109, 232):  # broken pipe / no data
                raise _winerror("PeekNamedPipe")
            return
        while available.value:
            size = min(available.value, 65_536)
            buffer = ctypes.create_string_buffer(size)
            read = wintypes.DWORD()
            if not kernel32.ReadFile(output_read, buffer, size, ctypes.byref(read), None):
                error = ctypes.get_last_error()
                if error in (109, 232):
                    return
                raise _winerror("ReadFile(ConPTY output)")
            output.extend(buffer.raw[: read.value])
            available.value -= read.value
            if read.value == 0:
                return

    def visible_output() -> bytes:
        return re.sub(
            rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[_PXM][^\x1b]*\x1b\\",
            b"",
            output,
        )

    def wait_for_markers(markers: tuple[bytes, ...], timeout: float, description: str) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            drain()
            # Match the emitted stream directly: VT cursor and screen updates
            # can make a regex-based visible-text projection lossy.
            if all(marker in output for marker in markers):
                return
            exit_code = wintypes.DWORD()
            if kernel32.GetExitCodeProcess(process.hProcess, ctypes.byref(exit_code)) and exit_code.value != 259:
                raise RuntimeError(f"standalone TUI exited before {description} (status={exit_code.value})")
            time.sleep(0.025)
        raw_tail = bytes(output[-2_000:])
        snippet = visible_output()[-2_000:].decode(errors="replace")
        raise TimeoutError(
            f"standalone TUI did not reach {description} within {timeout} seconds; "
            f"captured {len(output)} terminal bytes; visible output: {snippet!r}; "
            f"raw tail: {raw_tail!r}"
        )

    def wait_for_partial_reply(partial: bytes, complete: bytes, timeout: float) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            drain()
            if partial in output:
                if complete in output:
                    raise RuntimeError("standalone TUI received the complete reply before the partial-stream check")
                return
            exit_code = wintypes.DWORD()
            if kernel32.GetExitCodeProcess(process.hProcess, ctypes.byref(exit_code)) and exit_code.value != 259:
                raise RuntimeError(f"standalone TUI exited before rendering partial streamed text (status={exit_code.value})")
            time.sleep(0.025)
        snippet = visible_output()[-2_000:].decode(errors="replace")
        raise TimeoutError(f"standalone TUI did not render partial streamed text within {timeout} seconds: {snippet!r}")

    def send_keys(keys: bytes) -> None:
        written = wintypes.DWORD()
        buffer = ctypes.create_string_buffer(keys)
        if not kernel32.WriteFile(input_write, buffer, len(keys), ctypes.byref(written), None):
            raise _winerror("WriteFile(ConPTY input)")
        if written.value != len(keys):
            raise OSError(f"ConPTY accepted {written.value} of {len(keys)} input bytes")
        if not kernel32.WriteFile(child_stdin_write, buffer, len(keys), ctypes.byref(written), None):
            raise _winerror("WriteFile(TUI stdin)")
        if written.value != len(keys):
            raise OSError(f"TUI accepted {written.value} of {len(keys)} input bytes")

    try:
        security = SecurityAttributes(ctypes.sizeof(SecurityAttributes), None, False)
        for read_handle, write_handle in ((ctypes.byref(input_read), ctypes.byref(input_write)),
                                          (ctypes.byref(output_read), ctypes.byref(output_write))):
            if not kernel32.CreatePipe(read_handle, write_handle, ctypes.byref(security), 0):
                raise _winerror("CreatePipe")
        if not kernel32.CreatePipe(
            ctypes.byref(child_stdin_read), ctypes.byref(child_stdin_write), ctypes.byref(security), 0
        ):
            raise _winerror("CreatePipe(TUI stdin)")

        result = kernel32.CreatePseudoConsole(
            Coord(100, 24), input_read, output_write, 0, ctypes.byref(pseudoconsole)
        )
        if result != 0:
            raise OSError(f"CreatePseudoConsole failed with HRESULT 0x{result & 0xFFFFFFFF:08X}")

        attribute_size = ctypes.c_size_t()
        kernel32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(attribute_size))
        attribute_storage = ctypes.create_string_buffer(attribute_size.value)
        attribute_list = ctypes.cast(attribute_storage, wintypes.LPVOID)
        if not kernel32.InitializeProcThreadAttributeList(attribute_list, 1, 0, ctypes.byref(attribute_size)):
            raise _winerror("InitializeProcThreadAttributeList")
        attribute_list_initialized = True
        if not kernel32.UpdateProcThreadAttribute(
            attribute_list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            ctypes.cast(pseudoconsole, wintypes.LPVOID),
            ctypes.sizeof(HPCON),
            None,
            None,
        ):
            raise _winerror("UpdateProcThreadAttribute(PSEUDOCONSOLE)")

        startup = StartupInfoEx()
        startup.StartupInfo.cb = ctypes.sizeof(StartupInfoEx)
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES
        startup.StartupInfo.hStdInput = child_stdin_read
        startup.StartupInfo.hStdOutput = output_write
        startup.StartupInfo.hStdError = output_write
        startup.lpAttributeList = attribute_list
        command_line = ctypes.create_unicode_buffer(f'"{tui_path}"')
        environment = "\0".join(
            f"{key}={value}" for key, value in sorted(env.items(), key=lambda item: item[0].upper())
        ) + "\0\0"
        environment_block = ctypes.create_unicode_buffer(environment)
        for handle, description in (
            (child_stdin_read, "TUI stdin"),
            (output_write, "ConPTY output"),
        ):
            if not kernel32.SetHandleInformation(handle, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT):
                raise _winerror(f"SetHandleInformation({description})")
        if not kernel32.CreateProcessW(
            str(tui_path),
            command_line,
            None,
            None,
            True,
            EXTENDED_STARTUPINFO_PRESENT | 0x00000400,  # CREATE_UNICODE_ENVIRONMENT
            environment_block,
            None,
            ctypes.byref(startup.StartupInfo),
            ctypes.byref(process),
        ):
            raise _winerror("CreateProcessW(ConPTY child)")
        process_created = True
        close(input_read)
        close(output_write)

        wait_for_markers(
            (b"connected", b"SESSIONS", b"VEASEL", session_title.encode()),
            30,
            "its connected screen with the seeded session",
        )
        send_keys(b"s")
        wait_for_markers((b"MODEL SETTINGS", "● All".encode()), 5, "provider settings")
        for _ in range(5):
            send_keys(b"\t")
            time.sleep(0.2)
            drain()
            exit_code = wintypes.DWORD()
            if kernel32.GetExitCodeProcess(process.hProcess, ctypes.byref(exit_code)) and exit_code.value != 259:
                raise RuntimeError(f"standalone TUI exited while cycling provider groups (status={exit_code.value})")

        output.clear()
        send_keys(b"anthorpic")
        wait_for_markers((b"1/210", b"Anthropic"), 5, "typo-tolerant provider search")
        output.clear()
        send_keys(b"\x1b")
        wait_for_markers((b"SESSIONS", b"q quit"), 5, "the home session list after leaving settings")

        output.clear()
        send_keys(b"\r")
        wait_for_markers((b"Message Veasel",), 5, "the selected session composer")
        output.clear()
        send_keys(b"Stream incrementally\r")
        wait_for_partial_reply(b"Streaming fixture", b"Streaming fixture reply arrives in two pieces", 15)
        wait_for_markers((b"arrives in two pieces",), 30, "the mock provider response in the transcript")
        wait_for_persisted_reply(env["VEASEL_API_URL"], session_id, "Streaming fixture reply arrives in two pieces")
        output.clear()
        send_keys(b"\x10")
        wait_for_markers((b"Commands",), 5, "the command palette after the assistant reply")
        output.clear()
        send_keys(b"quit")
        wait_for_markers((b"Quit",), 5, "the quit command in the palette")
        send_keys(b"\r")
        if kernel32.WaitForSingleObject(process.hProcess, 5_000) != 0:
            snippet = visible_output()[-2_500:].decode(errors="replace")
            raise TimeoutError(f"standalone TUI did not exit through the command palette: {snippet}")
        exit_code = wintypes.DWORD()
        if not kernel32.GetExitCodeProcess(process.hProcess, ctypes.byref(exit_code)) or exit_code.value != 0:
            raise RuntimeError(f"standalone TUI exited unsuccessfully (status={exit_code.value})")
    finally:
        if process_created and kernel32.WaitForSingleObject(process.hProcess, 0) == 0x102:
            kernel32.TerminateProcess(process.hProcess, 1)
            kernel32.WaitForSingleObject(process.hProcess, 2_000)
        if attribute_list_initialized:
            kernel32.DeleteProcThreadAttributeList(attribute_list)
        if pseudoconsole:
            kernel32.ClosePseudoConsole(pseudoconsole)
        close(input_read)
        close(input_write)
        close(output_read)
        close(output_write)
        close(child_stdin_read)
        close(child_stdin_write)
        close(process.hThread)
        close(process.hProcess)
