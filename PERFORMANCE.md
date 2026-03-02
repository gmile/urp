# Performance

## Benchmarks

Compare URP against [Gotenberg](https://gotenberg.dev/) end-to-end:

```sh
docker compose --file benchmarks/docker-compose.yml up --detach --wait
mix run benchmarks/bench.exs
```

The benchmark fixture (`benchmarks/fixtures/benchmark.docx`) uses
Liberation fonts. Regenerate it with:

```sh
uv run --with python-docx --with Pillow --with numpy benchmarks/generate_fixture.py
```

### Results (Apple M3 Max)

Both URP and Gotenberg run LibreOffice 26.2.0 on Debian (glibc,
trixie-backports).

**Small document** (benchmark.docx, 2.6 MB → 221-page PDF):

```
Name                         ips        average  deviation         median         99th %
URP → Debian glibc          1.05         0.95 s     ±7.60%         0.94 s         1.20 s
Gotenberg (HTTP)            0.81         1.23 s     ±7.47%         1.19 s         1.42 s
```

**Large document** (benchmark-15mb.docx, 15.5 MB → 62 MB PDF):

```
Name                         ips        average  deviation         median         99th %
URP → Debian glibc         0.145         6.87 s     ±7.44%         6.73 s         7.44 s
Gotenberg (HTTP)           0.087        11.45 s     ±1.21%        11.45 s        11.54 s
```

URP is **27% faster** for small documents, **67% faster** for large
ones. The advantage grows with document size because Gotenberg's
Go/HTTP overhead (multipart parsing, queue management, response
framing) scales linearly.

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

## Container image

See `benchmarks/Dockerfile.soffice-debian` or inline:

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
ENV HOST=0.0.0.0
ENV PORT=2002
EXPOSE ${PORT}
CMD soffice --headless --norestore \
    --accept="socket,host=${HOST},port=${PORT},tcpNoDelay=1;urp;"
```

This uses glibc, gets LibreOffice from trixie-backports (latest Fresh
release), and produces a ~607 MB image. `fonts-liberation` provides
metric-compatible replacements for Arial, Times New Roman, and Courier
New. `fonts-crosextra-carlito` provides a Calibri replacement.

| Setup | 2.6 MB | 15.5 MB | LO version | Image size |
|-------|--------|---------|------------|------------|
| URP → Debian glibc | 0.94 s | 6.73 s | 26.2.0 | ~607 MB |
| Gotenberg (Debian glibc) | 1.19 s | 11.45 s | 26.2.0 | ~1.86 GB |

## PDF output

URP and Gotenberg produce identical PDFs when using the same
LibreOffice version and fonts. The only differences are
non-deterministic metadata and font object ordering (see below).

### Determinism

Consecutive conversions of the same document on the **same soffice
process** produce byte-identical PDFs (after stripping four metadata
fields). Different soffice processes produce PDFs with identical
visual content but different byte representations.

**What differs between soffice processes:**

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

Within a single soffice process, output is fully deterministic.
Stripping the four metadata fields (`CreationDate`, `ModDate`, `/ID`,
`DocChecksum`) from two consecutive conversions yields byte-identical
files. This means a **single long-lived soffice instance** (the
normal URP deployment) produces reproducible output.

**Can this be made fully reproducible?** Not currently.
[Bug 160033](https://bugs.documentfoundation.org/show_bug.cgi?id=160033)
tracks this upstream. `SOURCE_DATE_EPOCH` does not help — LibreOffice's
PDF writer ignores it. Post-processing with
[`qpdf --deterministic-id`](https://qpdf.readthedocs.io/en/stable/cli.html)
can fix metadata but not font object reordering.

## Using `libreofficedocker/alpine`

The pre-built [`libreofficedocker/alpine`](https://hub.docker.com/r/libreofficedocker/alpine)
image works with URP out of the box, but has two structural drawbacks
compared to a custom Debian image.

### musl allocator overhead

Alpine uses musl libc, whose [`mallocng`](https://git.musl-libc.org/cgit/musl/tree/src/malloc/mallocng/malloc.c)
allocator relies on `mmap`/`munmap` for most allocations. LibreOffice does thousands of
small alloc/free cycles during PDF rendering, each becoming a kernel
syscall on musl. `strace -f -c` during a single conversion:

| Metric | Alpine (musl) | Alpine (musl + jemalloc) | Debian (glibc) |
|--------|---------------|--------------------------|----------------|
| `mmap`/`munmap` syscalls | 21,432 | 276 | 25 |
| `mmap`/`munmap` time | 140 ms | ~1 ms | ~0.05 ms |

This is [inherent to musl](https://docs.bell-sw.com/alpaquita-linux/latest/how-to/malloc/)
and can be mitigated with
[`LD_PRELOAD=/usr/lib/libjemalloc.so.2`](https://gist.github.com/toshimaru/b8e528c4be807612185277cc9da52b5a)
(install jemalloc first).

### Image bloat

Despite Alpine's reputation for small images,
`libreofficedocker/alpine` is 1.78 GB — nearly 3x a minimal Debian
image. It bundles OpenJDK 11, 130+ Noto font packages for every
writing system, and 450 packages total. A Debian image with just
LibreOffice and the fonts you need is smaller and easier to audit.

### Benchmark

As of March 2026, Alpine ships LO 25.8.x (Still line) while Debian
trixie-backports has 26.2.x (Fresh). The benchmark fixture uses
Liberation fonts — present in both images. Carlito (Calibri
replacement) is missing from the stock Alpine image, so documents
using Calibri will produce different layout unless `font-carlito` is
installed.

| Setup | 2.6 MB | 15.5 MB | LO version | Image size |
|-------|--------|---------|------------|------------|
| URP → Debian glibc | 0.94 s | 6.73 s | 26.2.0 | ~607 MB |
| URP → Alpine musl | 1.20 s | 11.11 s | 25.8.1 | ~1.78 GB |
| Gotenberg (Debian glibc) | 1.19 s | 11.45 s | 26.2.0 | ~1.86 GB |

### Reproducing the strace analysis

Start the benchmark containers, then attach `strace` to the Alpine
soffice process, trigger a conversion, and compare:

```sh
docker compose --file benchmarks/docker-compose.yml up --detach --wait

SOFFICE=benchmarks-soffice-1

# Install strace
docker exec $SOFFICE apk add --no-cache strace

# Find soffice PID
docker exec $SOFFICE pgrep -f soffice.bin
# => 44

# Syscall summary during one conversion
docker exec -d $SOFFICE strace -f -c -p 44 -o /tmp/strace_summary.txt
mix run -e '{:ok, _} = URP.convert({:binary, File.read!("benchmarks/fixtures/benchmark.docx")}, filter: "writer_pdf_Export", output: :binary)'
docker exec $SOFFICE sh -c 'kill -INT $(pgrep strace)'
docker exec $SOFFICE cat /tmp/strace_summary.txt

# mmap-only trace (count lines to see allocation volume)
docker exec -d $SOFFICE strace -f -e trace=mmap,munmap -p 44 -o /tmp/strace_mmap.txt
# ... trigger conversion ...
docker exec $SOFFICE wc -l /tmp/strace_mmap.txt
```

