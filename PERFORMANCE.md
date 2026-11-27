# Performance

What a conversion does, how long it takes and where the time goes. Every
number here comes from a script in `benchmarks/` that you can run against your
own `soffice`; expect different figures from a different machine, LibreOffice
or document.

The ones below are from an Apple M3 Max with Elixir 1.20.5 on Erlang/OTP 29,
talking to LibreOffice 26.8.3 on the same machine.

## A conversion, call by call

`benchmarks/calls.exs` traces one conversion and prints every round trip it
makes to `soffice`: how long it took, the bytes sent and received, and the UNO
method called, with its arguments.

```
$ mix run benchmarks/calls.exs test/fixtures/sample3.docx

sample3.docx: 34375 bytes in, 93349 bytes out, writer_pdf_Export

     time, ms      sent, B  received, B  call
         0.38          171           62  XSimpleFileAccess.openFileWrite("file:///tmp/urp_in_kS8AdhFnEYGrs8ynB8LBeXQK")
         0.29        34502            9  XOutputStream.writeBytes(<34375 bytes>)
         0.41          122            9  XOutputStream.closeOutput()
        29.87          201           62  XComponentLoader.loadComponentFromURL("file:///tmp/urp_in_kS8AdhFnEYGrs8ynB8LBeXQK", "_blank", 0, [Hidden: true])
         0.25          153           15  XInterface.queryInterface(XStorable2)
        14.36          206            9  XStorable2.storeToURL("file:///tmp/urp_out_VRwesRDqCUmUR9dCRaj9u5-L", [FilterName: "writer_pdf_Export"])
         0.26          172           62  XSimpleFileAccess.openFileRead("file:///tmp/urp_out_VRwesRDqCUmUR9dCRaj9u5-L")
         0.35          125        93367  XInputStream.readBytes(1048576)
         0.19          121            9  XInputStream.closeInput()
         0.18          172            9  XSimpleFileAccess.kill("file:///tmp/urp_out_VRwesRDqCUmUR9dCRaj9u5-L")
         0.17          152           15  XInterface.queryInterface(XCloseable)
         1.34          122            9  XCloseable.close(true)
         0.20          171            9  XSimpleFileAccess.kill("file:///tmp/urp_in_kS8AdhFnEYGrs8ynB8LBeXQK")
        48.25        36390        93646  in 13 round trips, of 48.51 ms in all
```

Read top to bottom, that is the whole of a conversion:

| Calls | What happens |
|-------|--------------|
| `openFileWrite`, `writeBytes`, `closeOutput` | the document is written to a temp file on `soffice`'s side |
| `loadComponentFromURL` | `soffice` loads it |
| `queryInterface(XStorable2)`, `storeToURL` | and exports it to a second temp file |
| `openFileRead`, `readBytes`, `closeInput` | the result is read back |
| `kill` | the result's temp file is deleted |
| `queryInterface(XCloseable)`, `close` | the document is closed |
| `kill` | the document's temp file is deleted |

The methods are named as the
[LibreOffice API reference](https://api.libreoffice.org/docs/idl/ref/) names
them. A larger document adds one `writeBytes` or `readBytes` for each further
chunk; nothing else changes.

## How long it takes

`benchmarks/latency.exs` runs a document through one connection a number of
times.

```sh
mix run benchmarks/latency.exs test/fixtures/sample3.docx 200
mix run benchmarks/latency.exs test/fixtures/sample1.xlsx 200 calc_pdf_Export
```

| Document | Result | Fastest | Median | 99th percentile | A second |
|----------|--------|---------|--------|-----------------|----------|
| `sample3.docx`, 34 KB | 93 KB PDF | 44.0 ms | 49.6 ms | 58.0 ms | 20.1 |
| `sample1.xlsx`, 29 KB | 514 KB PDF | 35.6 ms | 39.0 ms | 50.9 ms | 25.2 |

A connection converts one document at a time, so that is also what one
`soffice` gets through. More throughput takes more `soffice` processes, with a
connection each.

## Where the time goes

Nearly all of it is `soffice` at work. In the trace above, loading takes 30 ms
of 48, exporting 14 and closing 1; the other ten calls come to under 3 ms
between them.

`benchmarks/profile.exs` measures the rest from inside the VM: CPU time and
garbage collected per conversion, then the functions with the most time and the
most memory allocated in them.

```sh
mix run benchmarks/profile.exs test/fixtures/sample3.docx 100
```

For that document each conversion costs the VM 1.4 ms of CPU and leaves 42 KiB
to collect. The CPU time is almost all socket calls: one send and two receives,
for the header and the body, per round trip.

## How a document travels

A document goes to `soffice` over the URP socket and is written to a temp file
on its side; the result is read back from another. Both are moved a chunk at a
time (1 MiB unless the pool's `:chunk_size` says otherwise), so neither end
holds more of the document than that in one message, and nothing has to be
shared with `soffice` on disk. A document never lands on a process heap either:
chunks are passed along as references to the binaries the socket produced.

`benchmarks/transfer.exs` moves bytes there and back without converting
anything, in chunks of several sizes:

```
$ mix run benchmarks/transfer.exs 50

50 MiB each way

     chunk    up, ms  down, ms
    64 KiB       130       167
   256 KiB        48        72
  1024 KiB        25        53
  4096 KiB        31        50
```

## PDF output

A long-lived `soffice` produces byte-identical output for the same document
across conversions, apart from the timestamps and document IDs in its metadata
(`CreationDate`, `ModDate`, `/ID`, `/DocChecksum`).

Different `soffice` processes produce visually identical PDFs but assign fonts
to different PDF object numbers.
[Bug 160033](https://bugs.documentfoundation.org/show_bug.cgi?id=160033) tracks
this upstream. [`qpdf --deterministic-id`](https://qpdf.readthedocs.io/en/stable/cli.html)
can normalize the metadata but not the font object ordering.
