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
         0.32        34619           65  XMultiComponentFactory.createInstanceWithArgumentsAndContext("com.sun.star.io.SequenceInputStream", [<34375 bytes>], <object>)
        33.47          282           65  XComponentLoader.loadComponentFromURL("private:stream", "_blank", 0, [Hidden: true, InputStream: <object>])
         0.21          156           15  XInterface.queryInterface(XStorable2)
        15.43          209            9  XStorable2.storeToURL("file:///tmp/urp_out_KWSQ9pXom8FBDlaGLhoMIJvB", [FilterName: "writer_pdf_Export"])
         0.22          175           65  XSimpleFileAccess.openFileRead("file:///tmp/urp_out_KWSQ9pXom8FBDlaGLhoMIJvB")
         0.31          128        93367  XInputStream.readBytes(1048576)
         0.18          124            9  XInputStream.closeInput()
         0.20          175            9  XSimpleFileAccess.kill("file:///tmp/urp_out_KWSQ9pXom8FBDlaGLhoMIJvB")
         1.31          124            9  XComponent.dispose()
        51.64        35992        93613  in 9 round trips, of 51.81 ms in all
```

Read top to bottom, that is the whole of a conversion:

| Calls | What happens |
|-------|--------------|
| `createInstanceWithArgumentsAndContext` | the document is sent, and `soffice` makes a stream over its bytes |
| `loadComponentFromURL` | `soffice` loads it from that stream |
| `queryInterface(XStorable2)`, `storeToURL` | and exports it to a temp file on its side |
| `openFileRead`, `readBytes`, `closeInput` | the result is read back |
| `kill` | the temp file is deleted |
| `dispose` | the document is closed |

After the last of them `soffice` is told, without a reply to wait for, that
the stream is done with, and lets go of the document's bytes.

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
| `sample3.docx`, 34 KB | 93 KB PDF | 43.0 ms | 50.6 ms | 70.7 ms | 19.6 |
| `sample1.xlsx`, 29 KB | 514 KB PDF | 33.9 ms | 39.9 ms | 50.0 ms | 24.8 |

A connection converts one document at a time, so that is also what one
`soffice` gets through. More throughput takes more `soffice` processes, with a
connection each.

## Where the time goes

Nearly all of it is `soffice` at work. In the trace above, loading takes 33 ms
of 52, exporting 15 and closing 1; the other six calls come to under 2 ms
between them.

`benchmarks/profile.exs` measures the rest from inside the VM: CPU time and
garbage collected per conversion, then the functions with the most time and the
most memory allocated in them.

```sh
mix run benchmarks/profile.exs test/fixtures/sample3.docx 100
```

For that document each conversion costs the VM 1.1 ms of CPU and leaves 34 KiB
to collect. The CPU time is almost all socket calls: one send and two receives,
for the header and the body, per round trip.

## How a document travels

A document goes to `soffice` over the URP socket in one message, and `soffice`
loads it from memory. The result is written to a temp file on its side and read
back a chunk at a time (1 MiB unless the pool's `:chunk_size` says otherwise),
so no message received holds more of it than that. Nothing has to be shared
with `soffice` on disk, and a document never lands on a process heap: it is
passed along as references to binaries.

`benchmarks/transfer.exs` moves bytes there and back without converting
anything:

```
$ mix run benchmarks/transfer.exs 50

50 MiB up in one message: 30 ms

down, by chunk:
    64 KiB    191 ms
   256 KiB     76 ms
  1024 KiB     58 ms
  4096 KiB     60 ms
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
