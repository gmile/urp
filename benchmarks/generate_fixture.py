#!/usr/bin/env python3
"""Generate benchmarks/fixtures/benchmark.docx — a document with lorem
ipsum text, tables, and JPEG images.

Uses only Liberation Sans/Serif/Mono fonts (available via fonts-liberation
on Debian and Alpine). All proprietary font references from python-docx's
default template are stripped in post-processing.

Requirements (auto-installed by uv):
    uv run --with python-docx --with Pillow --with numpy benchmarks/generate_fixture.py
    uv run --with python-docx --with Pillow --with numpy benchmarks/generate_fixture.py --size 50
"""

import argparse
import io
import os
import re
import zipfile

import numpy as np
from docx import Document
from docx.shared import Inches
from PIL import Image

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")

LOREM = (
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod "
    "tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim "
    "veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea "
    "commodo consequat. Duis aute irure dolor in reprehenderit in voluptate "
    "velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint "
    "occaecat cupidatat non proident, sunt in culpa qui officia deserunt "
    "mollit anim id est laborum. Cras mattis consectetur purus sit amet "
    "fermentum. Donec id elit non mi porta gravida at eget metus. Maecenas "
    "faucibus mollis interdum. Praesent commodo cursus magna, vel scelerisque "
    "nisl consectetur et. Vivamus sagittis lacus vel augue laoreet rutrum "
    "faucibus dolor auctor. Integer posuere erat a ante venenatis dapibus."
)

SECTIONS = [
    "System Overview", "Architecture", "Protocol Design",
    "Connection Management", "Type System", "Serialization",
    "Transport Layer", "Error Handling", "Pool Management",
    "File Operations", "Performance", "Benchmarking",
    "Containers", "Configuration", "PDF Output",
    "Memory Analysis", "Network Profiling", "Optimization",
    "Testing", "Recommendations",
]


def make_jpeg(w=1600, h=1200, seed=0):
    """Generate a colorful JPEG (~500 KB) that doesn't compress in ZIP."""
    ys, xs = np.mgrid[:h, :w]
    r = ((xs * 3 + seed * 37) % 256).astype(np.uint8)
    g = ((ys * 5 + seed * 73) % 256).astype(np.uint8)
    b = (((xs + ys) + seed * 11) % 256).astype(np.uint8)
    arr = np.stack([r, g, b], axis=2)
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, format="JPEG", quality=95)
    buf.seek(0)
    return buf


def build_docx(target_mb=2.5):
    """Build a .docx document targeting approximately target_mb megabytes.

    Scales the number of chapters and images to reach the target size.
    Each chapter contributes ~130 KB (text + tables + 1 image).
    """
    # Each chapter ≈ 130 KB: ~30 KB text + ~100 KB JPEG
    chapters_needed = max(len(SECTIONS), int(target_mb * 1024 / 130))
    doc = Document()

    doc.add_heading("URP Performance Benchmark", level=0)
    doc.add_paragraph(
        "Auto-generated document for benchmarking document conversion. "
        "Contains lorem ipsum text, tables, and embedded images. "
        "Uses only system-default fonts."
    )
    doc.add_page_break()

    for i in range(1, chapters_needed + 1):
        section = SECTIONS[(i - 1) % len(SECTIONS)]
        doc.add_heading(f"Chapter {i}: {section}", level=1)

        for sub in range(1, 6):
            doc.add_heading(f"{i}.{sub} Section Details", level=2)

            for _ in range(8):
                doc.add_paragraph(LOREM)

            if sub % 2 == 0:
                table = doc.add_table(rows=8, cols=4)
                table.style = "Table Grid"
                for ri, row in enumerate(table.rows):
                    for ci, cell in enumerate(row.cells):
                        cell.text = (
                            f"Header {ci + 1}" if ri == 0 else f"{ri * 1000 + ci}"
                        )

            if sub == 3:
                img = make_jpeg(1600, 1200, seed=i)
                doc.add_picture(img, width=Inches(5.5))

        doc.add_page_break()

    buf = io.BytesIO()
    doc.save(buf)
    buf.seek(0)
    return buf


# Font replacements: proprietary -> Liberation equivalent
FONT_MAP = {
    "Calibri Light": "Liberation Sans",
    "Calibri": "Liberation Sans",
    "Arial": "Liberation Sans",
    "Times New Roman": "Liberation Serif",
    "Cambria": "Liberation Serif",
    "Tahoma": "Liberation Sans",
    "Courier": "Liberation Mono",
    "Symbol": "Liberation Sans",
    "\uff2d\uff33 \u30b4\u30b7\u30c3\u30af": "Liberation Sans",  # MS Gothic
    "\uff2d\uff33 \u660e\u671d": "Liberation Serif",  # MS Mincho
    "\ub9d1\uc740 \uace0\ub515": "Liberation Sans",  # Malgun Gothic
}


def strip_proprietary_fonts(raw_docx):
    """Post-process the ZIP to replace all proprietary font references."""
    out = io.BytesIO()
    with zipfile.ZipFile(raw_docx) as zin, zipfile.ZipFile(
        out, "w", zipfile.ZIP_DEFLATED
    ) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)

            if item.filename.endswith(".xml"):
                text = data.decode("utf-8")

                # Replace proprietary fonts everywhere in all XML files
                for old, new in FONT_MAP.items():
                    text = text.replace(f'typeface="{old}"', f'typeface="{new}"')
                    text = text.replace(f'w:ascii="{old}"', f'w:ascii="{new}"')
                    text = text.replace(f'w:hAnsi="{old}"', f'w:hAnsi="{new}"')
                    text = text.replace(f'w:cs="{old}"', f'w:cs="{new}"')
                    text = text.replace(f'w:eastAsia="{old}"', f'w:eastAsia="{new}"')
                    text = text.replace(f'w:name="{old}"', f'w:name="{new}"')

                if "theme" in item.filename:
                    # Remove per-script font elements (CJK, Thai, etc.)
                    text = re.sub(
                        r'\s*<a:font\s+script="[^"]*"\s+typeface="[^"]*"\s*/>',
                        "",
                        text,
                    )

                data = text.encode("utf-8")

            zout.writestr(item, data)

    out.seek(0)
    return out


# Font attributes in OOXML (rFonts attributes + theme typeface + font declarations)
_FONT_ATTRS = re.compile(
    r'(?:typeface|w:ascii|w:hAnsi)="([^"]+)"'
    r"|<w:font\s+w:name=\"([^\"]+)\""
)


def verify_fonts(path):
    """Return set of font names referenced in the docx."""
    fonts = set()
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            if not name.endswith(".xml"):
                continue
            c = z.read(name).decode("utf-8", errors="replace")
            for m in _FONT_ATTRS.finditer(c):
                val = m.group(1) or m.group(2)
                if val:
                    fonts.add(val)
    return sorted(fonts)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate benchmark .docx fixture")
    parser.add_argument(
        "--size",
        type=float,
        default=2.5,
        help="Target file size in MB (default: 2.5)",
    )
    args = parser.parse_args()

    os.makedirs(FIXTURES, exist_ok=True)

    if args.size <= 5:
        out = os.path.join(FIXTURES, "benchmark.docx")
    else:
        out = os.path.join(FIXTURES, f"benchmark-{int(args.size)}mb.docx")

    raw = build_docx(target_mb=args.size)
    clean = strip_proprietary_fonts(raw)

    with open(out, "wb") as f:
        f.write(clean.read())

    size = os.path.getsize(out)
    fonts = verify_fonts(out)
    print(f"Created {out}: {size / 1024:.0f} KB ({size / (1024 * 1024):.1f} MB)")
    print(f"Fonts: {fonts}")
