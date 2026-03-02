# Performance

URP converts documents by talking directly to `soffice` over TCP.
This page compares URP against [Gotenberg](https://gotenberg.dev/),
the most popular LibreOffice-based conversion service.

## Benchmarks

```sh
docker compose --file benchmarks/docker-compose.yml up --detach --wait
mix run benchmarks/bench.exs
```

Both URP and Gotenberg run LibreOffice 26.2.0 on Debian (glibc).
The fixture uses Liberation fonts only — regenerate with
`uv run --with python-docx --with Pillow --with numpy benchmarks/generate_fixture.py`
(pass `--size 15` for the large variant).

### Results (Apple M3 Max)

**2.6 MB input → 221-page PDF:**

```
Name                         ips        average  deviation         median         99th %
URP                         1.05         0.95 s     ±7.60%         0.94 s         1.20 s
Gotenberg                   0.81         1.23 s     ±7.47%         1.19 s         1.42 s
```

**15.5 MB input → 62 MB PDF:**

```
Name                         ips        average  deviation         median         99th %
URP                        0.145         6.87 s     ±7.44%         6.73 s         7.44 s
Gotenberg                  0.087        11.45 s     ±1.21%        11.45 s        11.54 s
```

**27% faster** for small documents, **67% faster** for large ones.
The gap grows because Gotenberg's Go/HTTP overhead (multipart parsing,
queue management, response framing) scales with document size, while
URP talks to soffice directly over a TCP socket.

## Container image

See `benchmarks/Dockerfile.soffice-debian`. Minimal Debian trixie-slim
with LibreOffice from trixie-backports, `fonts-liberation` (metric-
compatible with Arial/Times/Courier), and `fonts-crosextra-carlito`
(Calibri replacement). ~564 MB vs Gotenberg's ~1.86 GB.

## PDF output

URP and Gotenberg produce identical PDFs when using the same
LibreOffice version and fonts.

A **single long-lived soffice instance** (the normal URP deployment)
produces byte-identical output across consecutive conversions — the
only varying fields are timestamps and document IDs in metadata
(`CreationDate`, `ModDate`, `/ID`, `/DocChecksum`).

Different soffice processes produce visually identical PDFs but assign
fonts to different PDF object numbers (~32 KB of byte differences for
a 221-page PDF). This is likely hash table iteration order in LO's
font subsetting.
[Bug 160033](https://bugs.documentfoundation.org/show_bug.cgi?id=160033)
tracks this upstream. [`qpdf --deterministic-id`](https://qpdf.readthedocs.io/en/stable/cli.html)
can normalize metadata but not font object ordering.

## Using `libreofficedocker/alpine`

The pre-built [`libreofficedocker/alpine`](https://hub.docker.com/r/libreofficedocker/alpine)
image works with URP out of the box but has two structural drawbacks.

**musl allocator overhead.** Alpine uses musl libc, whose
[`mallocng`](https://git.musl-libc.org/cgit/musl/tree/src/malloc/mallocng/malloc.c)
allocator issues `mmap`/`munmap` for most allocations — 21,432
syscalls per conversion vs 25 on glibc. This adds ~260 ms. It's
[inherent to musl](https://docs.bell-sw.com/alpaquita-linux/latest/how-to/malloc/)
and can be mitigated with
[`LD_PRELOAD=/usr/lib/libjemalloc.so.2`](https://github.com/jemalloc/jemalloc/wiki/Getting-Started).

**Image bloat.** Despite Alpine's small-image reputation,
`libreofficedocker/alpine` is 1.78 GB — nearly 3x the Debian image.
It bundles OpenJDK 11, 130+ Noto font packages, and 450 packages
total.

As of March 2026, Alpine ships LO 25.8.x (Still) while Debian
trixie-backports has 26.2.x (Fresh). Carlito is missing from the
stock Alpine image (`apk add font-carlito` to fix).

| Setup | 2.6 MB | 15.5 MB | LO version | Image size |
|-------|--------|---------|------------|------------|
| URP → Debian glibc | 0.94 s | 6.73 s | 26.2.0 | ~564 MB |
| URP → Alpine musl | 1.20 s | 11.11 s | 25.8.1 | ~1.78 GB |
| Gotenberg (Debian glibc) | 1.19 s | 11.45 s | 26.2.0 | ~1.86 GB |

<details>
<summary>Reproducing the strace analysis</summary>

```sh
docker compose --file benchmarks/docker-compose.yml up --detach --wait
SOFFICE=benchmarks-soffice-1
docker exec $SOFFICE apk add --no-cache strace
docker exec $SOFFICE pgrep -f soffice.bin  # note the PID

# Syscall summary during one conversion
docker exec -d $SOFFICE strace -f -c -p <PID> -o /tmp/strace.txt
mix run -e '{:ok, _} = URP.convert({:binary, File.read!("benchmarks/fixtures/benchmark.docx")}, filter: "writer_pdf_Export", output: :binary)'
docker exec $SOFFICE sh -c 'kill -INT $(pgrep strace)'
docker exec $SOFFICE cat /tmp/strace.txt
```

</details>
