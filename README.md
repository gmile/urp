# URP

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Converts documents to PDF by talking directly to an off-the-shelf `soffice`
container over a TCP socket — no custom images, wrappers, or sidecars needed.

## Why?

LibreOffice is the best open-source tool for converting office documents to
PDF, but integrating it into a web app typically requires intermediate layers:

- **[unoserver](https://github.com/unoconv/unoserver)** — Python daemon that wraps soffice and exposes an HTTP API
- **[Gotenberg](https://gotenberg.dev/)** — Go service that wraps unoserver (which wraps soffice)
- **Python UNO bindings** (`uno`, `unoconv`) — require Python and LibreOffice's UNO runtime installed together

Each layer adds deployment complexity, resource overhead, and failure modes.

URP skips all of that. It speaks the binary UNO Remote Protocol directly over
TCP to a stock `soffice` process — the same protocol LibreOffice uses
internally. No Python runtime, no wrapper services, no custom Docker images.

## Installation

Add `urp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:urp, "~> 0.5"}
  ]
end
```

## Prerequisites

A running `soffice` process with a URP socket listener:

```sh
soffice --headless --norestore \
  --accept="socket,host=0.0.0.0,port=2002,tcpNoDelay=1;urp;"
```

Or via Docker:

```sh
docker run \
  --detach \
  --name soffice \
  --publish 2002:2002 \
  libreofficedocker/alpine:3.23 \
  soffice --headless --norestore \
    --accept="socket,host=0.0.0.0,port=2002,tcpNoDelay=1;urp;"
```

## Usage

A default connection pool starts automatically, connecting to `localhost:2002`.
No supervision tree setup needed.

```elixir
# File path — writes PDF to temp file by default
{:ok, pdf_path} = URP.convert("/path/to/input.docx")

# Explicit output path
{:ok, "/tmp/out.pdf"} = URP.convert("/path/to/input.docx", output: "/tmp/out.pdf")

# Return bytes in memory
{:ok, pdf_bytes} = URP.convert("/path/to/input.docx", output: :binary)

# Raw bytes input
{:ok, pdf_bytes} = URP.convert({:binary, docx_bytes}, output: :binary)

# Enumerable input (e.g. File.stream!, S3 download stream)
{:ok, pdf_path} = URP.convert(File.stream!("huge.docx", 65_536))
```

Configure the default pool in `config/runtime.exs`:

```elixir
config :urp, :default,
  host: "soffice",
  port: 2002,
  pool_size: 1
```

### Output modes

The `:output` option controls where converted bytes go:

```elixir
# Default — write to temp file, return path
{:ok, tmp_path} = URP.convert(input)

# Write to specific path
{:ok, path} = URP.convert(input, output: "/tmp/output.pdf")

# Return bytes in memory
{:ok, pdf_bytes} = URP.convert(input, output: :binary)

# Stream chunks to a callback
:ok = URP.convert(input, output: fn chunk -> send_chunk(chunk) end)
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

## Scope

URP implements the subset of the UNO API needed for document conversion:

| UNO interface | Methods used | Purpose |
|---|---|---|
| [`XComponentLoader`](https://api.libreoffice.org/docs/idl/ref/interfacecom_1_1sun_1_1star_1_1frame_1_1XComponentLoader.html) | `loadComponentFromURL` | Open documents (from file URL or `private:stream`) |
| [`XStorable2`](https://api.libreoffice.org/docs/idl/ref/interfacecom_1_1sun_1_1star_1_1frame_1_1XStorable2.html) | `storeToURL` | Export documents (to file URL or `private:stream`) |
| [`XCloseable`](https://api.libreoffice.org/docs/idl/ref/interfacecom_1_1sun_1_1star_1_1util_1_1XCloseable.html) | `close` | Release document resources |
| [`XInputStream`](https://api.libreoffice.org/docs/idl/ref/interfacecom_1_1sun_1_1star_1_1io_1_1XInputStream.html) | `readBytes`, `readSomeBytes`, `skipBytes`, `available`, `closeInput` | Feed document bytes to soffice |
| [`XOutputStream`](https://api.libreoffice.org/docs/idl/ref/interfacecom_1_1sun_1_1star_1_1io_1_1XOutputStream.html) | `writeBytes`, `flush`, `closeOutput` | Receive converted output from soffice |

The output format is controlled by [export filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)
passed via [`MediaDescriptor`](https://api.libreoffice.org/docs/idl/ref/servicecom_1_1sun_1_1star_1_1document_1_1MediaDescriptor.html).
Common filters: `writer_pdf_Export`, `calc_pdf_Export`, `impress_pdf_Export`.

Other UNO APIs (editing, formatting, macros, etc.) are not implemented.

## Architecture

| Module | Role |
|---|---|
| `URP` | Public API — converts via pool with test stub support |
| `URP.Pool` | NimblePool — connection pooling with DisposedException retry |
| `URP.Test` | Test helpers — per-process stubs via NimbleOwnership |
| `URP.Bridge` | Mid-level — UNO operations (handshake, load, store, close, streaming) |
| `URP.Stream` | Bidirectional URP dispatch for XInputStream/XOutputStream |
| `URP.Protocol` | Low-level — binary wire format (framing, encoding, reply parsing) |

## Design: soffice as a network service

This library treats soffice as an external network service — your Elixir app
connects to it over TCP. soffice must be deployed and scaled separately
(e.g. as a sidecar container, a separate Kubernetes deployment, or a standalone
server).

An alternative approach would be to bundle soffice into the same image as
the Elixir app and manage it via Erlang Ports:

| | Network service (this library) | Embedded via Port |
|---|---|---|
| **Scaling** | Scale soffice independently | Tied to app instances |
| **Isolation** | soffice crash doesn't affect the BEAM | Port crash is contained but messier |
| **Deployment** | Separate image, simpler app image | Single image, larger and more complex |
| **Latency** | TCP overhead (negligible on local network) | No network hop |
| **Multiple instances** | Deploy N soffice containers | Spawn N Ports per app node |
| **Complexity** | Needs orchestration (Docker/K8s) | Needs Port supervision, lifecycle management |

The network approach is simpler to implement and fits well with containerized
deployments where soffice already runs as a separate service.

### Kubernetes: scaling note

The soffice Docker image is ~1.7GB, but image layers are shared across all
containers on the same node — running 10 pods doesn't use 10× the disk.
Each soffice process uses ~50-150MB RSS (spiking during conversion). The
per-container namespace overhead (~10-20MB) is negligible in comparison.

Multiple pods give you health checks, restart policies, and per-instance
resource limits for free. The equivalent with embedded Ports means managing
all of that in application code.

Tested with [`libreofficedocker/alpine:3.23`](https://hub.docker.com/r/libreofficedocker/alpine).

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
