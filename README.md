# URP

[![Hex.pm](https://img.shields.io/hexpm/v/urp.svg)](https://hex.pm/packages/urp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/urp/readme.html)

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Talks directly to a `soffice` process over a TCP socket —
no Python, no wrappers, no sidecars.

## Installation

```elixir
{:urp, "~> 0.8"}
```

## Prerequisites

A running `soffice` with a URP socket listener:

```sh
docker build --tag soffice --file benchmarks/Dockerfile.soffice-debian benchmarks/
docker run --detach --name soffice --publish 2002:2002 soffice
```

## Usage

A default pool connects to `localhost:2002` automatically.

```elixir
# file path, {:binary, bytes}, or any Enumerable as input
{:ok, pdf_path} =
  URP.convert("/path/to/input.docx",
    filter: "writer_pdf_Export",
    filter_data: [Quality: 90, ReduceImageResolution: true, MaxImageResolution: 150]
  )

# output: :binary to get bytes in memory
{:ok, pdf} = URP.convert({:binary, docx_bytes}, filter: "writer_pdf_Export", output: :binary)

{:ok, "26.2.0.3"} = URP.version()
{:ok, filters}    = URP.filters()
```

See `URP.convert/2` for all options ([filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html),
[FilterData properties](https://wiki.documentfoundation.org/Macros/Python_Guide/PDF_export_filter_data)).

### Configuration

```elixir
# config/runtime.exs
config :urp, :default,
  host: "soffice",
  port: 2002,
  pool_size: 1
```

> #### pool_size {: .warning}
>
> Each connection needs its own soffice instance. With `pool_size: 3`,
> run 3 soffice containers — one per connection. Concurrent operations
> on a single soffice process are not safe.

### Testing

Stub conversions in tests — no running soffice needed. See `URP.Test`.

```elixir
URP.Test.stub(fn _input, _opts -> {:ok, "/tmp/fake.pdf"} end)
assert {:ok, _} = MyApp.generate_invoice(order)
```

### Telemetry

Every operation emits `[:urp, :call, :stop]` with queue, service, and
total time measurements. See `URP.Telemetry`.

## Performance

See [PERFORMANCE.md](PERFORMANCE.md) for benchmarks and container image recommendations.

## References

- [UNO Binary Protocol Spec](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol)
- [binaryurp source](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/) — reader.cxx, writer.cxx, marshal.cxx
- [Export filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)

## Releasing

```sh
./release.sh patch   # or minor, major
git push origin main --tags
```

## License

MIT — see [LICENSE](LICENSE).
