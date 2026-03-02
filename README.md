# URP

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Converts documents by talking directly to an off-the-shelf `soffice`
container over a TCP socket — no custom images, wrappers, or sidecars needed.

## Why?

Existing approaches to LibreOffice integration —
[unoserver](https://github.com/unoconv/unoserver),
[Gotenberg](https://gotenberg.dev/),
Python UNO bindings — each add an intermediate layer with its own
deployment complexity and failure modes.

URP speaks the binary protocol directly over TCP to a stock `soffice`
process. No Python runtime, no wrapper services, no custom Docker images.

## Installation

Add `urp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:urp, "~> 0.6"}
  ]
end
```

## Prerequisites

A running `soffice` process with a URP socket listener. A minimal
custom-built Debian image is recommended — it's faster and smaller
than alternatives (see [PERFORMANCE.md](PERFORMANCE.md)), but a
pre-built Alpine image like `libreofficedocker/alpine` works too:

```sh
docker run \
  --detach \
  --name soffice \
  --publish 2002:2002 \
  soffice-debian \
  soffice --headless --norestore \
    --accept="socket,host=0.0.0.0,port=2002,tcpNoDelay=1;urp;"
```

See `benchmarks/Dockerfile.soffice-debian` for the image definition,
or use your own Debian/Ubuntu image with LibreOffice installed.

## Usage

A default connection pool starts automatically, connecting to `localhost:2002`.
No supervision tree setup needed.

```elixir
# File path — convert to PDF, write to temp file
{:ok, pdf_path} = URP.convert("/path/to/input.docx", filter: "writer_pdf_Export")

# Explicit output path
{:ok, "/tmp/out.pdf"} = URP.convert("/path/to/input.docx", filter: "writer_pdf_Export", output: "/tmp/out.pdf")

# Return bytes in memory
{:ok, pdf_bytes} = URP.convert("/path/to/input.docx", filter: "writer_pdf_Export", output: :binary)

# Raw bytes input
{:ok, pdf_bytes} = URP.convert({:binary, docx_bytes}, filter: "calc_pdf_Export", output: :binary)

# Enumerable input (e.g. File.stream!, S3 download stream)
{:ok, pdf_path} = URP.convert(File.stream!("huge.docx", 65_536), filter: "writer_pdf_Export")

# Stream chunks to a callback
:ok = URP.convert(input, filter: "writer_pdf_Export", output: fn chunk -> send_chunk(chunk) end)

# Query soffice version
{:ok, "25.8.1.1"} = URP.version()
```

Configure the default pool in `config/runtime.exs`:

```elixir
config :urp, :default,
  host: "soffice",
  port: 2002,
  pool_size: 1
```

### Named pools

For multiple soffice instances, configure named pools:

```elixir
config :urp, :pools,
  spreadsheets: [host: "soffice-2", port: 2002, pool_size: 3]
```

Named pools are started on first use:

```elixir
{:ok, pdf} = URP.convert({:binary, xlsx_bytes}, pool: :spreadsheets, filter: "calc_pdf_Export")
```

## Testing

Stub conversions in tests — no running soffice needed:

```elixir
test "generates invoice PDF" do
  URP.Test.stub(fn _input, _opts ->
    {:ok, "/tmp/fake.pdf"}
  end)

  assert {:ok, _pdf} = MyApp.generate_invoice(order)
end
```

Stubs are per-process and propagate through `$callers` (Tasks, GenServers).
See `URP.Test` for details.

Integration tests require soffice on `localhost:2002`:

```sh
mix test
```

## Performance

See [PERFORMANCE.md](PERFORMANCE.md) for benchmarks, container image
recommendations (Debian vs Alpine), and `strace` analysis of allocator
overhead.

## Scope

Implements document conversion and version detection via UNO. The output
format is controlled by [export filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)
(`writer_pdf_Export`, `calc_pdf_Export`, `impress_pdf_Export`, `Markdown`, etc.).
Other UNO APIs (editing, formatting, macros) are not implemented.

## Architecture

| Module | Role |
|---|---|
| `URP` | Public API — convert, version, test stubs |
| `URP.Bridge` | Mid-level — UNO operations (handshake, load, store, close, streaming) |
| `URP.Stream` | Bidirectional URP dispatch for XInputStream/XOutputStream |
| `URP.Protocol` | Low-level — binary wire format (framing, encoding, reply parsing) |

## References

- [UNO Binary Protocol Spec](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol)
- [binaryurp source](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/) — reader.cxx, writer.cxx, marshal.cxx
- [specialfunctionids.hxx](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/source/specialfunctionids.hxx)
- [typeclass.h](https://git.libreoffice.org/core/+/refs/heads/master/include/typelib/typeclass.h)
- [Export filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)

## License

MIT — see [LICENSE](LICENSE).

This is an independent implementation based on the public UNO protocol spec.
LibreOffice source was consulted as documentation for protocol details not
covered by the spec. No code was copied.
