#!/usr/bin/env python3
"""
resolve.py — 把 box64 崩溃日志粘进来，自动解出每个 PC 的函数/源码位置。

用法:
    # 1) 粘贴模式: 直接运行，把日志贴上去，Ctrl-D 结束
    python3 resolve.py

    # 2) 文件模式
    python3 resolve.py crash.log

    # 3) 管道模式
    hdc hilog | grep Box64Runner | python3 resolve.py

    # 4) 显式指定单个或多个 PC
    python3 resolve.py --pc 0x7ead5c 0x7b21e0
    python3 resolve.py --pc 0xe6e1b8 --asm           # 顺带反汇编 ±32 字节

环境变量 (可选):
    BOX64_BIN    带调试符号的 box64 路径 (默认 ~/HarmonyBox/out/box64)
    OHOS_SDK     OHOS NDK 根 (默认 ~/ohos-sdk/linux)
"""
from __future__ import annotations
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
DEFAULT_BOX64 = HOME / "HarmonyBox" / "out" / "box64"
DEFAULT_SDK   = Path(os.environ.get("OHOS_SDK", str(HOME / "ohos-sdk" / "linux")))

BOX64 = Path(os.environ.get("BOX64_BIN", str(DEFAULT_BOX64)))
LLVM  = DEFAULT_SDK / "native" / "llvm" / "bin"
A2L   = LLVM / "llvm-addr2line"
OBJD  = LLVM / "llvm-objdump"

# ----- 颜色 -----
def C(code, s): return f"\033[{code}m{s}\033[0m" if sys.stdout.isatty() else s
RED, GRN, YEL, CYA, DIM = (lambda c: lambda s: C(c, s))(31), \
                           (lambda c: lambda s: C(c, s))(32), \
                           (lambda c: lambda s: C(c, s))(33), \
                           (lambda c: lambda s: C(c, s))(36), \
                           (lambda c: lambda s: C(c, s))(2)

# ----- 正则 -----
# 1) 鸿蒙崩溃栈格式:  #07 pc 00000000007ead5c /path/to/box64
FRAME_RE  = re.compile(r"#(\d+)\s+pc\s+([0-9a-fA-F]+)\s+(\S+)")
# 2) box64 自打的:    x64pc=...   pc=0x...   PC: 0x...
INLINE_RE = re.compile(r"\b(?:x64pc|pc|PC|RIP)\s*[=:]\s*(0x[0-9a-fA-F]+|[0-9a-fA-F]{6,16})")
# 3) 兜底: 任何看起来像 box64 内部地址范围的 0x... (4MB ~ 32MB)
RANGE_RE  = re.compile(r"\b0x[0-9a-fA-F]{6,8}\b")

# ----- 工具 -----
def need_tool(p: Path, label: str) -> bool:
    if not p.exists():
        print(RED(f"[!] {label} not found: {p}"), file=sys.stderr)
        return False
    return True

def addr2line(addr: str) -> str:
    """Return 'func at file:line' (or chain for inlined)."""
    try:
        r = subprocess.run(
            [str(A2L), "-e", str(BOX64), "-f", "-C", "-i", "-p", addr],
            capture_output=True, text=True, timeout=15,
        )
    except Exception as e:
        return f"(addr2line failed: {e})"
    out = r.stdout.strip()
    if not out:
        return "(no debug info)"
    return out

def objdump_around(addr: str, before=16, after=48) -> str:
    try:
        a = int(addr, 16)
    except ValueError:
        return ""
    if not OBJD.exists():
        return ""
    start = max(0, a - before)
    end   = a + after
    try:
        r = subprocess.run(
            [str(OBJD), "-d",
             f"--start-address=0x{start:x}",
             f"--stop-address=0x{end:x}",
             str(BOX64)],
            capture_output=True, text=True, timeout=15,
        )
        return r.stdout
    except Exception:
        return ""

def normalize_pc(s: str) -> str:
    s = s.strip().lower()
    if not s.startswith("0x"):
        s = "0x" + s.lstrip("0")
    if s == "0x":
        s = "0x0"
    return s

def collect_pcs(text: str):
    """Return ordered list of (label, pc, raw_line). Dedup by pc."""
    seen = set()
    items = []
    # 1) 栈帧 — 只挑路径里包含 box64 的
    for m in FRAME_RE.finditer(text):
        idx, pc, path = m.group(1), normalize_pc(m.group(2)), m.group(3)
        if "box64" not in path.lower():
            continue
        if pc in seen: continue
        seen.add(pc)
        items.append((f"frame #{idx}", pc, path))
    # 2) 内联 pc/x64pc/PC/RIP=
    for m in INLINE_RE.finditer(text):
        pc = normalize_pc(m.group(1))
        if pc in seen: continue
        seen.add(pc)
        items.append(("inline", pc, m.group(0)))
    return items

def main():
    ap = argparse.ArgumentParser(description="Resolve box64 PCs to symbols.")
    ap.add_argument("file", nargs="?", help="crash log file (omit to read stdin)")
    ap.add_argument("--pc", nargs="+", help="resolve specific PC(s) directly")
    ap.add_argument("--asm", action="store_true",
                    help="also dump disassembly around each PC")
    ap.add_argument("--all", action="store_true",
                    help="also try every plausible 0xXXXXX as a PC (noisy)")
    args = ap.parse_args()

    print(DIM(f"[box64]      {BOX64}"))
    print(DIM(f"[addr2line]  {A2L}"))
    if not need_tool(BOX64, "box64 binary"): sys.exit(1)
    if not need_tool(A2L,   "llvm-addr2line"): sys.exit(1)
    print()

    # --- pcs from --pc ---
    if args.pc:
        items = [("--pc", normalize_pc(p), "") for p in args.pc]
    else:
        # --- read text ---
        if args.file:
            text = Path(args.file).read_text(errors="replace")
        elif sys.stdin.isatty():
            print(DIM("paste log, end with Ctrl-D:"), file=sys.stderr)
            text = sys.stdin.read()
        else:
            text = sys.stdin.read()

        items = collect_pcs(text)
        if args.all:
            seen = {pc for _, pc, _ in items}
            for m in RANGE_RE.finditer(text):
                pc = normalize_pc(m.group(0))
                if pc not in seen:
                    seen.add(pc); items.append(("guess", pc, ""))

    if not items:
        print(YEL("(no PC found in input)"))
        sys.exit(0)

    print(GRN(f"resolving {len(items)} address(es)\n"))
    for label, pc, ctx in items:
        sym = addr2line(pc)
        print(f"{CYA(label):<14} {YEL(pc)}")
        for line in sym.splitlines():
            print(f"   {line}")
        if ctx:
            print(DIM(f"   ({ctx[:80]})"))
        if args.asm:
            asm = objdump_around(pc)
            if asm:
                print(DIM("   --- disasm ---"))
                for line in asm.splitlines():
                    if line.strip():
                        print(DIM(f"   {line}"))
        print()

if __name__ == "__main__":
    main()