# URP

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Converts documents to PDF by talking directly to a LibreOffice `soffice`
process over a TCP socket.

No Python. No unoserver. No Gotenberg.

## Installation

Add `urp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:urp, "~> 0.1.0"}
  ]
end
```

For test stubbing support (optional):

```elixir
def deps do
  [
    {:urp, "~> 0.1.0"},
    {:nimble_ownership, "~> 1.0", only: :test}
  ]
end
```

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

## Configuration

Define a converter module and configure it via application config:

```elixir
# lib/my_app/converter.ex
defmodule MyApp.Converter do
  use URP, otp_app: :my_app
end
```

```elixir
# config/runtime.exs
config :my_app, MyApp.Converter,
  host: "soffice",
  port: 2002
```

Then call it anywhere in your app:

```elixir
{:ok, pdf_bytes} = MyApp.Converter.convert_stream(docx_bytes)
{:ok, pdf_bytes} = MyApp.Converter.convert_file_stream("/path/to/input.docx")
{:ok, output}    = MyApp.Converter.convert("/shared/input.docx", "/shared/output.pdf")
```


## Usage

### Direct (scripts, IEx)

No wrapper module or supervision tree needed:

```elixir
{:ok, pdf_bytes} = URP.convert_stream(docx_bytes, host: "localhost", port: 2002)
{:ok, pdf_bytes} = URP.convert_file_stream("/path/to/input.docx")
{:ok, output_path} = URP.convert("/shared/input.docx", "/shared/output.pdf")
```

### Supervised (production)

For serialized access (one conversion at a time), add `URP.Connection`:

```elixir
# application.ex
children = [
  {URP.Connection, otp_app: :my_app}
]

{:ok, pdf} = URP.Connection.convert_stream(docx_bytes)
```

For concurrent conversions, add `URP.Pool`:

```elixir
# application.ex
children = [
  {URP.Pool, otp_app: :my_app, pool_size: 4}
]

{:ok, pdf} = URP.Pool.convert_stream(docx_bytes)
```

### Sink (streaming output)

By default, converted bytes accumulate in memory. Use `:sink` to stream
output as it arrives:

```elixir
# Write to file
:ok = URP.convert_stream(docx_bytes, sink: {:path, "/tmp/output.pdf"})

# Stream to an HTTP response, S3 upload, etc.
:ok = URP.convert_stream(docx_bytes, sink: fn chunk -> send_chunk(chunk) end)
```

## Testing

Define a converter module with `use URP` and stub it in tests — no
running soffice needed:

```elixir
# test/test_helper.exs
URP.Test.start()
ExUnit.start()

# test/my_app/invoice_test.exs
test "generates invoice PDF" do
  URP.Test.stub(MyApp.Converter, fn _input, _opts ->
    {:ok, "%PDF-fake"}
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

## Architecture

| Module | Role |
|---|---|
| `URP` | Public API + `use URP` macro for wrapper modules |
| `URP.Connection` | Supervised GenServer — serialization, backpressure, timeouts |
| `URP.Pool` | NimblePool — concurrent conversions with connection pooling |
| `URP.Test` | Test helpers — per-process stubs via NimbleOwnership |
| `URP.Bridge` | Mid-level — UNO operations (handshake, load, store, close, streaming) |
| `URP.Stream` | Bidirectional URP dispatch for XInputStream/XOutputStream |
| `URP.Protocol` | Low-level — binary wire format (framing, encoding, reply parsing) |

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
