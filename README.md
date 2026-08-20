# URP

[![Hex.pm](https://img.shields.io/hexpm/v/urp.svg)](https://hex.pm/packages/urp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/urp/readme.html)

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Talks directly to a `soffice` process over a TCP socket —
no Python, no wrappers, no sidecars.

## Installation

```elixir
{:urp, "~> 0.10"}
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

# docx to Markdown, output as binary
{:ok, md} = URP.convert({:binary, docx_bytes}, filter: "Markdown", output: :binary)

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
> A single URP connection handles one operation at a time. LibreOffice accepts
> multiple connections to one soffice process, but they share process-wide
> state and generally do not improve conversion throughput. Keep `pool_size: 1`
> unless you have tested your workload. For predictable parallelism and fault
> isolation, use separate soffice processes with distinct profiles. The current
> pool sends every worker to the configured host and port; distributing workers
> across containers requires separate named pools or an external TCP balancer.

### Errors

A failure is `{:error, reason}`. A message string means soffice objected to the
document or the filter; an atom means the socket gave out — `:timeout` when
soffice stopped answering, `:closed` when it hung up, or a POSIX error. The two
call for different handling: retrying a document soffice refused is pointless,
and a wedged soffice is not the document's fault.

```elixir
case URP.convert(path, filter: "writer_pdf_Export", output: pdf) do
  {:ok, ^pdf} -> :converted
  {:error, reason} when is_atom(reason) -> {:unavailable, reason}
  {:error, message} -> {:refused, message}
end
```

### Testing

Stub conversions in tests — no running soffice needed. See `URP.Test`.

```elixir
URP.Test.stub(fn _input, _opts -> {:ok, "/tmp/fake.pdf"} end)
assert {:ok, _} = MyApp.generate_invoice(order)
```

`mix test` always runs the deterministic unit suite without probing local ports.
Run the complete suite, including the LibreOffice 26.2+ coverage, explicitly with:

```sh
docker compose --file benchmarks/docker-compose.yml up --detach --wait soffice
URP_INTEGRATION=1 nix develop --command mix test --include lo26
```

### Telemetry

Every operation emits a `[:urp, :call, :start]` event followed by either
`[:urp, :call, :stop]` or `[:urp, :call, :exception]`. Stop events include
queue, service, backoff, and total time. Connection retries emit
`[:urp, :connection, :retry]`. See `URP.Telemetry`.

## Performance

See [PERFORMANCE.md](PERFORMANCE.md) for benchmarks and container image recommendations.

## References

- [UNO Binary Protocol Spec](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol)
- [binaryurp source](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/) — reader.cxx, writer.cxx, marshal.cxx
- [Export filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)

## Releasing

```sh
./release.sh patch   # or minor, major
git push origin main
# Wait for main CI, then:
git push origin "v$(cat VERSION)"
```

## License

MIT — see [LICENSE](LICENSE).
