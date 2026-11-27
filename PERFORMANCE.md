# Performance

## How a document travels

A document goes to `soffice` over the URP socket and is written to a temp
file on its side; the result is read back from another. Both are moved a
chunk at a time (1 MiB unless the pool's `:chunk_size` says otherwise), so
neither end holds more of the document than that in one message, and nothing
has to be shared with `soffice` on disk.

Moving 50 MB each way through LibreOffice 26.2.5.1 on a local socket:

| Chunk | Upload | Read back |
|-------|--------|-----------|
| whole | 34 ms | 61 ms |
| 4 MB | 37 ms | 25 ms |
| 1 MB | 39 ms | 31 ms |
| 256 KB | 71 ms | 58 ms |
| 64 KB | 163 ms | 150 ms |

## Round trips

`benchmarks/calls.exs` lists every round trip one conversion makes, with its
time, by tracing the library from outside:

```sh
mix run benchmarks/calls.exs test/fixtures/sample3.docx
```

A document that fits in one chunk takes 13: three to upload it, one to load
it, two to export it, three to read the result back, two to close the
document and two to delete the temp files. For the 34 KB fixture that is
80 ms, of which 48 ms is `soffice` loading, 24 ms exporting, 4 ms closing and
a quarter of a millisecond is spent on this side.

## What the VM spends

`benchmarks/profile.exs` measures a run of conversions from inside the VM:
CPU time, garbage collection, and the functions with the most time and the
most memory allocated in them.

```sh
mix run benchmarks/profile.exs test/fixtures/sample3.docx 100
```

| Document | Wall | CPU in the VM | Collected |
|----------|------|---------------|-----------|
| 34 KB docx | 82 ms | 1.5 ms | 42 KiB |
| 8.7 MB JPEG | 1367 ms | 2.1 ms | 63 KiB |

The CPU time is almost all socket calls: one send and two receives, for the
header and the body, per round trip. A document never lands on a process
heap; chunks are passed along as references to the binaries the socket
produced.

## PDF output

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
