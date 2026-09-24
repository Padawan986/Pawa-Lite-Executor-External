"""Local init.bin build (no Studio ritual needed).

Concatenates fiu/Emulator.lua + fiu/bootstrap_emu.luau exactly like the
classic build.py (local fiu + bootstrap tail), compiles with the bundled
compile.exe, RSB1-encrypts like the game expects, and writes
luau/init.bin.new (never overwrites the live file).

Usage (from FunnyExecutor repo root):
    py src/FAPI/fiu/build_local.py
"""
import struct
import sys
from pathlib import Path

import zstandard

ROOT = Path(__file__).resolve().parent
EMU = ROOT / "Emulator.lua"
BOOT = ROOT / "bootstrap_emu.luau"
OUT = ROOT.parent / "luau" / "init.bin.new"

sys.path.insert(0, str(ROOT.parent.parent))
from FAPI.compiler import Luau


def encrypt_bytecode(raw: bytes) -> bytes:
    comp = zstandard.ZstdCompressor().compress(raw)
    buf = bytearray(b"RSB1" + struct.pack("<I", len(raw)) + comp)
    sign, hm = b"RSB1", 41
    key = [((buf[i] ^ sign[i]) - i * hm) & 0xFF for i in range(4)]
    out = bytearray(len(buf))
    for i in range(len(buf)):
        out[i] = buf[i] ^ ((key[i % 4] + i * hm) & 0xFF)
    return bytes(out)


def main() -> int:
    emu = EMU.read_text(encoding="utf-8")
    boot = BOOT.read_text(encoding="utf-8")
    built = (
        "-- ExtractThis (local build: Emulator.lua + bootstrap_emu.luau).\n"
        "local fiu = (function()\n" + emu + "\nend)()\n" + "\n" + boot
    )
    print(f"source: {len(built)} chars")
    compiled = Luau.compile(built)
    print(f"compiled: {len(compiled)} bytes")
    enc = encrypt_bytecode(compiled)
    print(f"encrypted: {len(enc)} bytes")
    # round-trip check through our own decryptor
    back = Luau.decrypt_bytecode(enc)
    assert back == compiled, "RSB1 round-trip mismatch!"
    print("round-trip ok")
    OUT.write_bytes(enc)
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
