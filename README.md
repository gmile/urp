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

Or via Docker:

```sh
docker run -d --name soffice \
  -p 2002:2002 \
  -v /tmp:/tmp \
  libreofficedocker/alpine:3.23 \
  soffice --headless --invisible --nologo \
    --accept="socket,host=0.0.0.0,port=2002,tcpNoDelay=1;urp;" \
    --norestore
```

## Usage

```elixir
# File-based — both paths must be visible to soffice at the same paths
URP.convert("/shared/input.docx", "/shared/output.pdf")

# With options
URP.convert("/shared/input.docx", "/shared/output.pdf",
  host: "soffice",
  port: 2002,
  filter: "writer_pdf_Export"
)
```

Or use the mid-level Bridge API directly:

```elixir
conn = URP.Bridge.open!("localhost", 2002)
doc = URP.Bridge.load_document!(conn, "file:///shared/input.docx")
URP.Bridge.store_to_url!(conn, doc, "file:///shared/output.pdf")
URP.Bridge.close_document!(conn, doc)
URP.Bridge.close!(conn)
```

## Architecture

Three layers:

| Module | Role |
|---|---|
| `URP` | Public API — `convert/3` |
| `URP.Bridge` | Mid-level — UNO operations (handshake, load, store, close) |
| `URP.Protocol` | Low-level — binary wire format (framing, encoding, reply parsing) |

## Streaming (planned)

The current implementation requires a shared filesystem between the caller and
soffice. A planned extension will use UNO's `XInputStream`/`XOutputStream`
interfaces to stream document bytes over the URP socket itself:

```elixir
# Planned API
{:ok, pdf_bytes} = URP.convert(docx_bytes, filter: "writer_pdf_Export")
```

Loading uses `loadComponentFromURL("private:stream", ...)` with an `InputStream`
property in the MediaDescriptor. Storing uses `storeToURL("private:stream", ...)`
with an `OutputStream` property. This requires handling bidirectional URP —
soffice calls `readBytes()`/`writeBytes()` on objects we export.

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

This is an independent protocol client. It does not include or link to any
LibreOffice code.
