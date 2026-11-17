"""Writes windows/src-tauri/icons/icon.ico from the Mac app's docs/icon.png.

Phase 5 replaces this with `cargo tauri icon` on a 1024 px PNG; for now the window needs an icon and the
bundler needs the file to exist.
"""
import struct
import zlib
from pathlib import Path

SRC = Path("docs/icon.png")
OUT = Path("windows/src-tauri/icons/icon.ico")


def read_png_size(path: Path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    # IHDR is the first chunk: width and height are the first two big-endian u32 after it.
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def ico_from_png(png_path: Path, out_path: Path, sizes):
    """An ICO holding the PNG bytes directly: Windows Vista and later accept PNG-compressed entries."""
    data = png_path.read_bytes()
    entries = b""
    images = b""
    offset = 6 + 16 * len(sizes)
    for size in sizes:
        entries += struct.pack("<BBBBHHII", size if size < 256 else 0, size if size < 256 else 0,
                               0, 0, 1, 32, len(data), offset)
        images += data
        offset += len(data)
    out_path.write_bytes(struct.pack("<HHH", 0, 1, len(sizes)) + entries + images)


def main():
    width, height = read_png_size(SRC)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    # One 256 px entry from the existing 1024 px PNG keeps the file small and the icon sharp at taskbar sizes.
    ico_from_png(SRC, OUT, [256])
    print(f"{OUT}: from {SRC.name} ({width}x{height}), {OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
