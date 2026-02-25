# URP

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Converts documents to PDF by talking directly to a LibreOffice `soffice`
process over a TCP socket.

No Python. No unoserver. No Gotenberg.

## Prerequisites

A running `soffice` process with a URP socket listener:

```sh
soffice --headless --invisible --nologo \
  --accept="socket,host=0.0.0.0,port=2002,tcpNoDelay=1;urp;" \
  --norestore
```

Or via Docker (volume mount only needed for file-based conversion):

```sh
docker run -d --name soffice \
  -p 2002:2002 \
  libreofficedocker/alpine:3.23 \
  soffice --headless --invisible --nologo \
    --accept="socket,host=0.0.0.0,port=2002,tcpNoDelay=1;urp;" \
    --norestore
```

## Usage

### Direct (scripts, IEx, tests)

No supervision tree needed:

```elixir
# In-memory bytes — no shared filesystem needed
{:ok, pdf_bytes} = URP.convert_stream(docx_bytes)

# File-backed streaming — reads on demand, not loaded into memory
{:ok, pdf_bytes} = URP.convert_file_stream("/path/to/input.docx")

# File-based — both paths must be visible to soffice
{:ok, output_path} = URP.convert("/shared/input.docx", "/shared/output.pdf")
```

### Supervised (production)

Add `URP.Connection` to your supervision tree for serialized access.
soffice is single-threaded — the GenServer ensures only one conversion
runs at a time, with callers queuing and timing out predictably.

```elixir
# application.ex
children = [
  {URP.Connection, host: "soffice", port: 2002}
]

# anywhere in your app
{:ok, pdf} = URP.Connection.convert_stream(docx_bytes)
{:ok, pdf} = URP.Connection.convert_file_stream("/path/to/input.docx")
{:ok, path} = URP.Connection.convert("/shared/in.docx", "/shared/out.pdf")
```

Multiple named connections for multiple soffice instances:

```elixir
children = [
  {URP.Connection, name: :soffice_1, host: "soffice-1", port: 2002},
  {URP.Connection, name: :soffice_2, host: "soffice-2", port: 2002}
]

URP.Connection.convert_stream(:soffice_1, docx_bytes)
```

## Architecture

| Module | Role |
|---|---|
| `URP` | Direct API — `convert/3`, `convert_stream/2`, `convert_file_stream/2` |
| `URP.Connection` | Supervised GenServer — serialization, backpressure, timeouts |
| `URP.Bridge` | Mid-level — UNO operations (handshake, load, store, close, streaming) |
| `URP.Stream` | Bidirectional URP dispatch for XInputStream/XOutputStream |
| `URP.Protocol` | Low-level — binary wire format (framing, encoding, reply parsing) |

## Streaming

No shared filesystem needed — bytes are transferred over the URP socket:

```elixir
{:ok, pdf_bytes} = URP.convert_stream(docx_bytes, filter: "writer_pdf_Export")
```

Uses `loadComponentFromURL("private:stream", ...)` with an `InputStream`
property and `storeToURL("private:stream", ...)` with an `OutputStream` property.
soffice calls `readBytes()`/`writeBytes()` on objects we export over the same
TCP connection (bidirectional URP).

## Tests

Integration tests require soffice on `localhost:2002`. They are included
automatically when soffice is reachable, skipped otherwise.

```sh
mix test
```

## References

- [UNO Binary Protocol Spec](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol)
- [binaryurp source](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/) — reader.cxx, writer.cxx, marshal.cxx
- [specialfunctionids.hxx](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/source/specialfunctionids.hxx)
- [typeclass.h](https://git.libreoffice.org/core/+/refs/heads/master/include/typelib/typeclass.h)
- [XInputStream](https://api.libreoffice.org/docs/idl/ref/interfacecom_1_1sun_1_1star_1_1io_1_1XInputStream.html), [XOutputStream](https://api.libreoffice.org/docs/idl/ref/interfacecom_1_1sun_1_1star_1_1io_1_1XOutputStream.html)
- [MediaDescriptor](https://api.libreoffice.org/docs/idl/ref/servicecom_1_1sun_1_1star_1_1document_1_1MediaDescriptor.html)

## License

MIT — see [LICENSE](LICENSE).

This is an independent implementation based on the public UNO protocol spec.
LibreOffice source was consulted as documentation for protocol details not
covered by the spec. No code was copied.
