# Performance

## Benchmarks

Compare URP against [Gotenberg](https://gotenberg.dev/) end-to-end:

```sh
docker compose --file benchmarks/docker-compose.yml up --detach --wait
mix run benchmarks/bench.exs
```

The benchmark fixture (`benchmarks/fixtures/benchmark.docx`) uses only
Liberation fonts — no proprietary font packages needed. Regenerate it
with:

```sh
uv run --with python-docx --with Pillow --with numpy benchmarks/generate_fixture.py
```

### Results (Apple M3 Max)

Debian soffice and Gotenberg both run LibreOffice 26.2.0 (glibc,
trixie-backports). Alpine uses LibreOffice 25.8.1 (musl).

**Small document** (benchmark.docx, 2.6 MB → 221-page PDF):

```
Name                         ips        average  deviation         median         99th %
URP → Debian glibc          1.05         0.95 s     ±7.60%         0.94 s         1.20 s
URP → Alpine musl           0.82         1.21 s     ±4.80%         1.20 s         1.40 s
Gotenberg (HTTP)            0.81         1.23 s     ±7.47%         1.19 s         1.42 s
```

**Large document** (benchmark-15mb.docx, 15.5 MB → 62 MB PDF):

```
Name                         ips        average  deviation         median         99th %
URP → Debian glibc         0.145         6.87 s     ±7.44%         6.73 s         7.44 s
URP → Alpine musl          0.090        11.11 s    ±26.20%        11.11 s        13.16 s
Gotenberg (HTTP)           0.087        11.45 s     ±1.21%        11.45 s        11.54 s
```

The advantage grows with document size: **27% faster** for small
documents, **67% faster** for large ones. Both URP and Gotenberg
transfer the full document and PDF over localhost TCP, but Gotenberg
adds Go/HTTP overhead (multipart parsing, queue management, response
framing) that scales with document size.

Generate the large fixture with:

```sh
uv run --with python-docx --with Pillow --with numpy benchmarks/generate_fixture.py --size 15
```

## Where time goes

Both URP and Gotenberg transfer the full input document and output PDF
over localhost TCP — neither avoids network I/O. The difference is what
else sits in the path:

**URP** talks directly to soffice over a TCP socket. File I/O goes
through soffice's `XSimpleFileAccess` UNO interface (SFA write for
input, SFA read for output), adding URP framing and a few extra
round-trips (open/write/close + open/read/close).

**Gotenberg** interposes a Go HTTP server between the client and
soffice. The Go server handles multipart parsing, queue management,
temporary file handling, and HTTP response framing. While its file I/O
to soffice is local (shared filesystem), the Go layer adds overhead that
exceeds URP's SFA cost.

For small documents (< 1 MB), the I/O overhead in both paths is
negligible and URP's advantage from fewer layers is even more
pronounced.

## musl libc and memory allocator overhead

`strace -f -c` on soffice during a single conversion reveals a dramatic
difference between Alpine (musl) and Debian (glibc):

| Metric | Alpine (musl) | Alpine (musl + jemalloc) | Debian (glibc) |
|--------|---------------|--------------------------|----------------|
| `mmap`/`munmap` syscalls | 21,432 | 276 | 25 |
| `mmap`/`munmap` time | 140 ms | ~1 ms | ~0.05 ms |

musl's `mallocng` allocator uses `mmap`/`munmap` for most allocations.
LibreOffice's PDF renderer does thousands of small alloc/free cycles
during conversion, each becoming a kernel syscall on musl. The direct
cost is ~140 ms, with additional indirect cost from TLB flushes and
cache pollution.

### Reproducing

Attach `strace` to the soffice process inside the container, trigger a
conversion, and compare:

```sh
# Install strace
docker exec soffice apk add --no-cache strace

# Find soffice PID
docker exec soffice pgrep -f soffice.bin
# => 44

# Syscall summary during one conversion
docker exec -d soffice strace -f -c -p 44 -o /tmp/strace_summary.txt
mix run -e '{:ok, _} = URP.convert({:binary, File.read!("benchmarks/fixtures/sample4.docx")}, filter: "writer_pdf_Export", output: :binary)'
docker exec soffice sh -c 'kill -INT $(pgrep strace)'
docker exec soffice cat /tmp/strace_summary.txt

# mmap-only trace (count lines to see allocation volume)
docker exec -d soffice strace -f -e trace=mmap,munmap -p 44 -o /tmp/strace_mmap.txt
# ... trigger conversion ...
docker exec soffice wc -l /tmp/strace_mmap.txt
```

For Gotenberg's soffice, you need `--cap-add SYS_PTRACE` on the
container (it runs as a non-root user):

```sh
docker run --detach --name gotenberg-bench \
  --publish 3002:3000 \
  --cap-add SYS_PTRACE \
  gotenberg/gotenberg:8.27.0
```

## Choosing a container image

**Use Debian.** See `benchmarks/Dockerfile.soffice-debian` or inline:

```dockerfile
FROM debian:trixie-slim
RUN echo 'deb http://deb.debian.org/debian trixie-backports main' \
      > /etc/apt/sources.list.d/backports.list && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends -t trixie-backports \
      libreoffice-core libreoffice-writer libreoffice-calc libreoffice-impress && \
    apt-get install -y --no-install-recommends \
      fonts-liberation fonts-crosextra-carlito && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
EXPOSE 2002
CMD ["soffice", "--headless", "--norestore", \
     "--accept=socket,host=0.0.0.0,port=2002,tcpNoDelay=1;urp;"]
```

This uses glibc, gets LibreOffice from trixie-backports (latest Fresh
release), and produces a ~607 MB image. `fonts-liberation` provides
metric-compatible replacements for Arial, Times New Roman, and Courier
New. `fonts-crosextra-carlito` provides a Calibri replacement.

| Setup | 2.6 MB | 15.5 MB | LO version | Image size |
|-------|--------|---------|------------|------------|
| URP → Debian glibc | 0.94 s | 6.73 s | 26.2.0 | ~607 MB |
| Gotenberg (Debian glibc) | 1.19 s | 11.45 s | 26.2.0 | ~1.86 GB |
| URP → Alpine musl | 1.20 s | 11.11 s | 25.8.1 | ~1.78 GB |

### Why not Alpine?

The pre-built `libreofficedocker/alpine` image has three problems:

1. **Outdated LibreOffice.** Alpine community repos track the Still
   line (25.8.x). Debian trixie-backports ships 26.2.x (Fresh).

2. **Larger image.** Despite Alpine's reputation for small images,
   `libreofficedocker/alpine` is 1.78 GB — nearly 3x the Debian
   image. It bundles OpenJDK 11 (~152 MB), 130+ Noto font packages
   for every script (CJK, Arabic, Devanagari, …), and 450 packages
   total vs 273 in Debian.

3. **musl allocator overhead.** musl's `mallocng` allocator uses
   `mmap`/`munmap` for most allocations (21,432 syscalls per
   conversion vs 25 on glibc). This adds ~260 ms per conversion.
   Mitigated by `LD_PRELOAD=/usr/lib/libjemalloc.so.2` but that
   requires installing jemalloc at runtime.

## PDF output differences

URP and Gotenberg produce identical PDFs when the same fonts are
available. The stock Alpine image (`libreofficedocker/alpine`) is
missing [Carlito](https://fonts.google.com/specimen/Carlito), the
metric-compatible open-source replacement for Calibri. Without it,
LibreOffice falls back to Noto Serif, which has wider glyphs and
produces more pages:

| Setup | Font used | Pages (sample4.docx) | File size |
|-------|-----------|---------------------|-----------|
| Alpine (no Carlito) | NotoSerif-Regular | 224 | 11.8 MB |
| Alpine + `font-carlito` | Carlito-Regular | 175 | 11.7 MB |
| Gotenberg (Debian) | Carlito-Regular | 175 | 11.7 MB |

To match Gotenberg output on Alpine, install the Carlito font package:

```sh
apk add --no-cache font-carlito
```

Or include it in your Dockerfile. Once fonts match, the PDFs are
identical in page count, dimensions, and text content — the only
differences are non-deterministic metadata and font object ordering
(see below).

## PDF determinism

Consecutive conversions of the same document on the **same soffice
process** produce byte-identical PDFs (after stripping four metadata
fields). Different soffice processes produce PDFs with identical
visual content but different byte representations.

### What differs between soffice processes

| Category | Bytes | Description |
|----------|-------|-------------|
| Font object ordering | ~32 KB | Fonts assigned to different PDF object numbers |
| Embedded font streams | (included above) | Same font data, swapped between objects |
| Glyph width arrays | (included above) | Follow their font objects |
| xref table offsets | ~50 | Shifted by stream reordering |
| `/CreationDate` | ~20 | Current system time |
| `/ID` | ~32 | Random document identifier |
| `/DocChecksum` | ~32 | Derived from ID |

For `benchmark.docx` (221-page PDF, 11.2 MB), the total byte
difference between two soffice processes is ~32 KB — all from font
object reordering and metadata. The rendered content is identical.

### Same-process determinism

Within a single soffice process, output is fully deterministic.
Stripping the four metadata fields (`CreationDate`, `ModDate`, `/ID`,
`DocChecksum`) from two consecutive conversions yields byte-identical
files. This means a **single long-lived soffice instance** (the
normal URP deployment) produces reproducible output.

### Cross-process non-determinism

Different soffice processes assign fonts to PDF objects in different
order. For example, one process may put LiberationSerif in object 689
while another puts LiberationSans-Bold there. The font data itself is
identical — just reordered. This is likely due to hash table iteration
order in LibreOffice's font subsetting.

### Can this be made fully reproducible?

**Not currently.** [Bug 160033](https://bugs.documentfoundation.org/show_bug.cgi?id=160033)
tracks this upstream ("soffice builds of pdf files are unreproducible").
`SOURCE_DATE_EPOCH` does not help — LibreOffice's PDF writer ignores
it. No `FilterData` properties control timestamps or document IDs.

Post-processing with [`qpdf --deterministic-id`](https://qpdf.readthedocs.io/en/stable/cli.html)
can fix the `/ID` and metadata fields, but cannot fix font object
reordering (a content-level difference). The practical workaround is
to use a single long-lived soffice process, which already produces
deterministic output.

## References

- [musl mallocng source](https://git.musl-libc.org/cgit/musl/tree/src/malloc/mallocng/malloc.c)
- [Alpaquita Linux — selecting a malloc variant](https://docs.bell-sw.com/alpaquita-linux/latest/how-to/malloc/)
- [jemalloc on Alpine](https://gist.github.com/toshimaru/b8e528c4be807612185277cc9da52b5a)
- [glibc malloc tunable parameters](https://www.gnu.org/software/libc/manual/html_node/Malloc-Tunable-Parameters.html)
- [Bug 160033 — soffice PDF export is unreproducible](https://bugs.documentfoundation.org/show_bug.cgi?id=160033)
- [qpdf --deterministic-id](https://qpdf.readthedocs.io/en/stable/cli.html)
