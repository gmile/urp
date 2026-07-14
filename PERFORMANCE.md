# Performance

URP converts documents by talking directly to `soffice` over TCP.
This page compares URP against [Gotenberg](https://gotenberg.dev/),
a popular LibreOffice-based conversion service.

## Benchmarks

```sh
docker compose --file benchmarks/docker-compose.yml up --detach --wait
nix develop --command mix run benchmarks/bench.exs
```

The results below were recorded on July 14, 2026, on Apple M3 Max with
Elixir 1.20.2 and Erlang/OTP 29.0.3. URP's Debian container ran
LibreOffice 26.2.4.2; Gotenberg 8.32.0 bundled LibreOffice 26.2.2.2.
The fixture uses Liberation fonts only — regenerate with
`uv run --with python-docx --with Pillow --with numpy benchmarks/generate_fixture.py`
(pass `--size 15` for the large variant).

### Results (Apple M3 Max)

**2.6 MB input → 221-page PDF:**

```
Name                         ips        average  deviation         median         99th %
URP → Debian glibc         1.31         0.76 s    ±14.66%         0.72 s         1.09 s
URP → Alpine musl          0.88         1.14 s     ±8.36%         1.16 s         1.21 s
Gotenberg (HTTP)            0.85         1.18 s     ±5.55%         1.16 s         1.36 s
```

**15.5 MB input → 62 MB PDF:**

```
Name                         ips        average  deviation         median         99th %
URP → Debian glibc        0.194         5.16 s     ±1.86%         5.18 s         5.24 s
URP → Alpine musl         0.143         6.98 s    ±13.31%         6.74 s         8.01 s
Gotenberg (HTTP)           0.137         7.30 s     ±2.32%         7.23 s         7.49 s
```

The Debian URP stack had **36% lower average latency** for the small
document and **29% lower average latency** for the large document than
Gotenberg. The absolute advantage grew from 0.42 s to 2.14 s. Alpine URP
was much closer to Gotenberg and had noticeably higher variance on the
large fixture. These measurements compare complete stacks with different
LibreOffice builds, C libraries, and container packaging; they do not
isolate dependency or runtime upgrades individually.

### Process overhead sanity check

`benchmarks/convert.exs` compares the persistent URP connection with a
cold `soffice --convert-to` process and Gotenberg using the 33 KB
`sample3.docx` fixture. Across ten timed iterations, the results were:

| Method | Average | Median | Range |
|--------|---------|--------|-------|
| URP | 45 ms | 45 ms | 42–49 ms |
| Gotenberg | 174 ms | 154 ms | 147–323 ms |
| LibreOffice CLI | 285 ms | 286 ms | 276–302 ms |

This is a process-overhead check, not an apples-to-apples transport
benchmark: URP reuses a live office process, while the CLI measurement
starts a new process for every conversion. One Gotenberg request was a
323 ms outlier; the median remained close to the previous run.

## I/O strategies

URP supports two I/O transfer strategies via the `:io` option, benchmarked
with `benchmarks/io_bench.exs`:

```sh
nix develop --command mix run benchmarks/io_bench.exs
```

**File I/O** (`:file`, default) writes temp files on soffice's filesystem
and transfers them over URP in ~6 round-trips. **Stream I/O** (`:stream`)
pipes bytes over the URP socket via XInputStream/XOutputStream — no temp
disk, but more round-trips.

Current results on Elixir 1.20.2 / OTP 29.0.3:

| Strategy | 2.7 MB | 16.2 MB | 35.0 MB |
|----------|--------|---------|---------|
| File → file | 1.13 s | 7.66 s | 39.17 s |
| File → stream | 1.19 s | 8.06 s | 37.19 s |
| Stream → file | 1.72 s | 11.59 s | 41.53 s |
| Stream → stream | 1.64 s | 9.06 s | 46.02 s |

Stream input remains the bottleneck because ZIP-based formats (docx,
xlsx, pptx) require thousands of XInputStream/XSeekable random-access
round-trips, but its measured penalty now ranges from roughly 12% to 52%
depending on document size and output mode. Stream output remains within
about 5% of file output. The 35 MB fixture completes only one iteration
per scenario with the default 10-second Benchee window, so treat those
figures as directional rather than statistically stable.

Soffice writes stream output in fixed
[32 767-byte chunks](https://github.com/LibreOffice/core/blob/libreoffice-26-2-0/sfx2/source/doc/docfile.cxx#L2573),
so the round-trip count is predictable.

| Strategy | Input | Output | Best for |
|----------|-------|--------|----------|
| `io: :file` | fast | fast | Default — best throughput |
| `io: {:file, :stream}` | fast | chunked | Large outputs without single big allocation |
| `io: {:stream, :file}` | slow | fast | No temp disk for input |
| `io: :stream` | slow | chunked | No temp disk at all |

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

As of July 2026, Alpine ships LO 25.8.x (Still) while Debian
trixie-backports has 26.2.x (Fresh). Carlito is missing from the
stock Alpine image (`apk add font-carlito` to fix).

| Setup | 2.6 MB | 15.5 MB | LO version | Image size |
|-------|--------|---------|------------|------------|
| URP → Debian glibc | 0.72 s | 5.05 s | 26.2.4.2 | ~564 MB |
| URP → Alpine musl | 1.18 s | 7.94 s | 25.8.1.1 | ~1.78 GB |
| Gotenberg (Debian glibc) | 1.16 s | 7.36 s | 26.2.2.2 | ~1.68 GB |

<details>
<summary>Reproducing the strace analysis</summary>

```sh
docker compose --file benchmarks/docker-compose.yml up --detach --wait
SOFFICE=benchmarks-soffice-alpine-1
docker exec $SOFFICE apk add --no-cache strace
docker exec $SOFFICE pgrep -f soffice.bin  # note the PID

# Syscall summary during one conversion
docker exec -d $SOFFICE strace -f -c -p <PID> -o /tmp/strace.txt
mix run -e '{:ok, _} = URP.convert({:binary, File.read!("benchmarks/fixtures/benchmark.docx")}, filter: "writer_pdf_Export", output: :binary)'
docker exec $SOFFICE sh -c 'kill -INT $(pgrep strace)'
docker exec $SOFFICE cat /tmp/strace.txt
```
</details>
