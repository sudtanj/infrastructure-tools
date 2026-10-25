#!/usr/bin/env python3
"""Where a crashed emulator died, from its minidump: the signal, the faulting
module and offset, and the code addresses found on the crashing thread's stack
(a rough backtrace). Only module names and offsets are printed, never memory
contents: the log is public.

  python3 minidump-summary.py FILE.dmp
"""
import struct
import sys

THREAD_LIST, MODULE_LIST, EXCEPTION = 3, 4, 6


def main(path):
    data = open(path, "rb").read()
    sig, _, count, dir_rva = struct.unpack_from("<4sIII", data, 0)
    if sig != b"MDMP":
        sys.exit(f"{path}: not a minidump")
    streams = {}
    for i in range(count):
        kind, size, rva = struct.unpack_from("<III", data, dir_rva + 12 * i)
        streams[kind] = (size, rva)

    modules = []
    if MODULE_LIST in streams:
        rva = streams[MODULE_LIST][1]
        (n,) = struct.unpack_from("<I", data, rva)
        for i in range(n):
            base, size, _, _, name_rva = struct.unpack_from("<QIIII", data, rva + 4 + 108 * i)
            (name_len,) = struct.unpack_from("<I", data, name_rva)
            name = data[name_rva + 4:name_rva + 4 + name_len].decode("utf-16-le", "replace")
            modules.append((base, base + size, name.rsplit("/", 1)[-1]))

    def where(addr):
        for lo, hi, name in modules:
            if lo <= addr < hi:
                return f"{name}+{addr - lo:#x}"
        return None

    if EXCEPTION not in streams:
        sys.exit(f"{path}: no exception record")
    rva = streams[EXCEPTION][1]
    tid, _, code, _, _, addr = struct.unpack_from("<IIIIQQ", data, rva)
    print(f"Crash: signal {code} in thread {tid} at {where(addr) or hex(addr)}")

    if THREAD_LIST in streams:
        rva = streams[THREAD_LIST][1]
        (n,) = struct.unpack_from("<I", data, rva)
        for i in range(n):
            t = rva + 4 + 48 * i
            (thread_id,) = struct.unpack_from("<I", data, t)
            if thread_id != tid:
                continue
            _, stack_size, stack_rva = struct.unpack_from("<QII", data, t + 24)
            frames = []
            for off in range(0, min(stack_size, 64 * 1024) - 7, 8):
                (value,) = struct.unpack_from("<Q", data, stack_rva + off)
                hit = where(value)
                if hit and (not frames or frames[-1] != hit):
                    frames.append(hit)
                if len(frames) >= 30:
                    break
            print("Code addresses on its stack, innermost first:")
            for f in frames:
                print(f"  {f}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
