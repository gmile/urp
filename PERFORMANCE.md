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
         0.54        34617           64  XMultiComponentFactory.createInstanceWithArgumentsAndContext("com.sun.star.io.SequenceInputStream", [<34375 bytes>], <object>)
        30.95          280           12  XComponentLoader.loadComponentFromURL("private:stream", "_blank", 0, [Hidden: true, InputStream: <object>])
         0.27          211           64  XMultiComponentFactory.createInstanceWithContext("com.sun.star.io.Pipe", <object>)
         0.20          155           15  XInterface.queryInterface(XStorable2)
        12.53          285            9  XStorable2.storeToURL("private:stream", [FilterName: "writer_pdf_Export", OutputStream: <object>])
         0.25          154           15  XInterface.queryInterface(XInputStream)
         0.21          123           13  XInputStream.available()
         0.34          127        93367  XInputStream.readBytes(93349)
         1.32          123            9  XComponent.dispose()
        46.59        36075        93568  in 9 round trips, of 46.79 ms in all
```

Read top to bottom, that is the whole of a conversion:

| Calls | What happens |
|-------|--------------|
| `createInstanceWithArgumentsAndContext` | the document is sent, and `soffice` makes a stream over its bytes |
| `loadComponentFromURL` | `soffice` loads it from that stream |
| `createInstanceWithContext` | `soffice` makes a pipe in its memory for the result |
| `queryInterface(XStorable2)`, `storeToURL` | and exports the document into it |
| `queryInterface(XInputStream)`, `available`, `readBytes` | the result is read back out of the pipe |
| `dispose` | the document is closed |

After the last of them `soffice` is told, without a reply to wait for, that
the stream, the pipe and the document are done with, and lets go of them.

The methods are named as the
[LibreOffice API reference](https://api.libreoffice.org/docs/idl/ref/) names
them. A larger result adds one `readBytes` for each further chunk; nothing
else changes.

## How long it takes

`benchmarks/latency.exs` runs a document through one connection a number of
times.

```sh
mix run benchmarks/latency.exs test/fixtures/sample3.docx 200
mix run benchmarks/latency.exs test/fixtures/sample1.xlsx 200 calc_pdf_Export
```

| Document | Result | Fastest | Median | 99th percentile | A second |
|----------|--------|---------|--------|-----------------|----------|
| `sample3.docx`, 34 KB | 93 KB PDF | 39.5 ms | 43.9 ms | 64.3 ms | 22.5 |
| `sample1.xlsx`, 29 KB | 514 KB PDF | 31.2 ms | 33.5 ms | 39.6 ms | 29.4 |

A connection converts one document at a time, so that is also what one
`soffice` gets through. More throughput takes more `soffice` processes, with a
connection each.

## Where the time goes

Nearly all of it is `soffice` at work. In the trace above, loading takes 31 ms
of 47, exporting 13 and closing 1; the other six calls come to under 3 ms
between them.

`benchmarks/profile.exs` measures the rest from inside the VM: CPU time and
garbage collected per conversion, then the functions with the most time and the
most memory allocated in them.

```sh
mix run benchmarks/profile.exs test/fixtures/sample3.docx 100
```

For that document each conversion costs the VM 1.2 ms of CPU and leaves 42 KiB
to collect. The CPU time is almost all socket calls: one send and two receives,
for the header and the body, per round trip.

## How a document travels

A document goes to `soffice` over the URP socket in one message, and `soffice`
loads it from memory. It exports the result into a pipe in its memory, which is
read back a chunk at a time (1 MiB unless the pool's `:chunk_size` says
otherwise), so no message received holds more of it than that. Nothing of ours
is written to `soffice`'s disk, and a document never lands on a process heap:
it is passed along as references to binaries.

`benchmarks/transfer.exs` moves bytes there and back without converting
anything:

```
$ mix run benchmarks/transfer.exs 50

50 MiB up in one message: 26 ms

down, by chunk:
    64 KiB    163 ms
   256 KiB     74 ms
  1024 KiB     60 ms
  4096 KiB     55 ms
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
