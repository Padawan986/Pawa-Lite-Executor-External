import hashlib
import os
import re
import struct
import subprocess
import tempfile
import time
from pathlib import Path

import zstandard

parent = Path(__file__).resolve().parent

class BytecodeError(Exception): pass

WINDOWS_RESERVED = {
    'CON', 'PRN', 'AUX', 'NUL',
    *(f'COM{i}' for i in range(1, 10)),
    *(f'LPT{i}' for i in range(1, 10)),
}

def safe_chunkname(chunkname: str) -> str:
    name = (chunkname or '').strip()
    name = re.sub(r'[\\/:*?"<>|]', '_', name)
    name = name.strip(' .') or 'chunk'
    if name.upper() in WINDOWS_RESERVED:
        name = '_' + name
    return name[:120]

class Luau:
    _CACHE_MAX = 300

    @staticmethod
    def _cache_dir() -> Path:
        d = Path(os.environ['APPDATA']) / 'Pawa-Lite-BetaV2' / 'bytecode_cache'
        d.mkdir(parents=True, exist_ok=True)
        return d

    @staticmethod
    def _cache_key(source: str | bytes, chunkname: str) -> str:
        raw = source.encode('utf-8') if isinstance(source, str) else bytes(source)
        h = hashlib.sha256()
        h.update(chunkname.encode('utf-8', 'replace'))
        h.update(b'\x00')
        h.update(raw)
        return h.hexdigest()

    @staticmethod
    def _cache_get(key: str) -> bytes | None:
        try:
            p = Luau._cache_dir() / (key + '.bin')
            if p.is_file():
                return p.read_bytes()
        except OSError:
            pass
        return None

    @staticmethod
    def _cache_put(key: str, data: bytes):
        try:
            d = Luau._cache_dir()
            (d / (key + '.bin')).write_bytes(data)
            files = sorted(d.glob('*.bin'), key=lambda p: p.stat().st_mtime)
            for old in files[:-Luau._CACHE_MAX]:
                try:
                    old.unlink()
                except OSError:
                    pass
        except OSError:
            pass

    _dll = None
    _dll_failed = False

    @staticmethod
    def _load_dll():
        # In-process Luau compiler (pawa_luau.dll next to compile.exe).
        # settled once; missing/broken DLL -> subprocess fallback.
        if Luau._dll is not None or Luau._dll_failed:
            return Luau._dll
        try:
            import ctypes
            dll = ctypes.CDLL(str(parent / 'luau' / 'pawa_luau.dll'))
            dll.pawa_compile.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64)]
            dll.pawa_compile.restype = ctypes.c_void_p
            dll.pawa_free.argtypes = [ctypes.c_void_p]
            dll.pawa_free.restype = None
            Luau._dll = dll
        except Exception:
            Luau._dll_failed = True
        return Luau._dll

    @staticmethod
    def _compile_fast(source: str | bytes) -> bytes | None:
        # Returns bytecode via DLL, or None when unavailable/failed
        # (caller falls back to compile.exe, which also yields error text).
        dll = Luau._load_dll()
        if dll is None:
            print('Pawa-Lite(Beta)V2 -- fallback auf compile.exe (pawa_luau.dll missing/broken)')
            return None
        try:
            import ctypes
            raw = source.encode('utf-8') if isinstance(source, str) else bytes(source)
            outlen = ctypes.c_uint64()
            ptr = dll.pawa_compile(raw, len(raw), ctypes.byref(outlen))
            if not ptr or not outlen.value:
                print('Pawa-Lite(Beta)V2 -- fallback auf compile.exe (DLL compile failed)')
                return None
            try:
                data = bytes(ctypes.string_at(ptr, outlen.value))
            finally:
                dll.pawa_free(ptr)
            if not data or data[:1] == b'\x00':
                # version byte 0 = Luau error marker, not bytecode
                print('Pawa-Lite(Beta)V2 -- fallback auf compile.exe (DLL syntax error)')
                return None
            return data
        except Exception as e:
            print(f'Pawa-Lite(Beta)V2 -- fallback auf compile.exe (DLL exception: {e})')
            return None

    @staticmethod
    def compile(source: str | bytes, chunkname: str = ''):
        key = Luau._cache_key(source, chunkname or '')
        hit = Luau._cache_get(key)
        if hit is not None:
            return hit
        data = Luau._compile_fast(source)
        if data is None:
            data = Luau._compile_uncached(source, chunkname)
        Luau._cache_put(key, data)
        return data

    @staticmethod
    def _compile_uncached(source: str | bytes, chunkname: str = ''):
        if chunkname:
            with tempfile.TemporaryDirectory(prefix='PawaLiteBetaV2-Chunk-') as tmpdir:
                name = safe_chunkname(chunkname)
                path = os.path.join(tmpdir, name)
                Luau._write_source(path, source)
                result = subprocess.run(
                    [parent/'luau'/'compile.exe', name, '--binary'],
                    capture_output=True,
                    cwd=tmpdir
                )
                if result.returncode != 0:
                    raise BytecodeError(
                        'Luau compile error:\n'
                        + result.stderr.decode('utf-8', 'replace').strip()
                    )
            return result.stdout

        path = tempfile.gettempdir() + f'\\PawaLiteBetaV2-Temp-Source-{os.getpid()}-{time.time_ns()}.luau'

        try:
            Luau._write_source(path, source)
            result = subprocess.run(
                [parent/'luau'/'compile.exe', path, '--binary'],
                capture_output=True
            )
            if result.returncode != 0:
                raise BytecodeError(
                    'Luau compile error:\n'
                    + result.stderr.decode('utf-8', 'replace').strip()
                )
        finally:
            try:
                os.remove(path)
            except OSError:
                pass

        return result.stdout

    @staticmethod
    def decrypt_bytecode(encrypted: bytes) -> bytes:
        if len(encrypted) < 8:
            raise BytecodeError('bytecode too short')

        sign = b'RSB1'
        hash_mul = 41

        buffer = bytearray(encrypted)
        key = [0] * 4

        for i in range(4):
            key[i] = ((buffer[i] ^ sign[i]) - i * hash_mul) & 0xFF

        for i in range(len(buffer)):
            buffer[i] ^= (key[i % 4] + i * hash_mul) & 0xFF

        if not buffer.startswith(sign):
            raise BytecodeError('decryption failed')

        decomp_size = struct.unpack_from('<I', buffer, 4)[0]

        if decomp_size == 0 or decomp_size > 50 * 1024 * 1024:
            raise BytecodeError('decompression failed')

        return zstandard.ZstdDecompressor().decompress(bytes(buffer[8:]), decomp_size)

    @staticmethod
    def _write_source(path: str, source: str | bytes):
        if type(source) == str:
            with open(path, 'w', encoding='utf-8') as f:
                f.write(source)
        else:
            with open(path, 'wb') as f:
                f.write(source)
