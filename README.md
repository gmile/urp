# URP

[![Hex.pm](https://img.shields.io/hexpm/v/urp.svg)](https://hex.pm/packages/urp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/urp/readme.html)

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Talks directly to a `soffice` process over a TCP socket —
no Python, no wrappers, no sidecars.

## Installation

```elixir
{:urp, "~> 0.12"}
```

## Prerequisites

A running `soffice` that accepts URP connections:

```sh
soffice --headless --norestore --accept="socket,host=127.0.0.1,port=2002,tcpNoDelay=1;urp;"
```

## Usage

```elixir
# a file path or {:binary, bytes} in; a path, :binary or a function out
{:ok, "/path/to/output.pdf"} =
  URP.convert("/path/to/input.docx",
    filter: "writer_pdf_Export",
    filter_data: [Quality: 90, ReduceImageResolution: true, MaxImageResolution: 150],
    output: "/path/to/output.pdf"
  )

{:ok, markdown} = URP.convert({:binary, docx_bytes}, filter: "Markdown", output: :binary)

{:ok, "26.2.0.3"} = URP.version()
{:ok, filters}    = URP.filters()
```

See `URP.convert/2` for all options ([filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html),
[FilterData properties](https://wiki.documentfoundation.org/Macros/Python_Guide/PDF_export_filter_data)),
and the `URP` module documentation for configuration, errors and what happens
to a conversion that outlives its timeout.

### Configuration

```elixir
# config/runtime.exs
config :urp, :default,
  host: "soffice",
  port: 2002,
  pool_size: 1
```

> #### pool_size and clustering {: .warning}
>
> A `soffice` process is only safe to convert one document at a time — running
> concurrent conversions against the same `soffice` can hang or fail it. URP
> identifies each remote `soffice` process and enforces one job at a time per
> `soffice` across every pool in the node and across connected Erlang nodes
> (for example via [DNSCluster](https://hexdocs.pm/dns_cluster)).
>
> For parallelism and fault isolation, run several `soffice` processes and
> point `host` at a name that resolves to all of them (a headless Kubernetes
> service or round-robin DNS record): the connections of a pool take the
> addresses in turn, so `pool_size: N` reaches all `N` processes while
> connections and document I/O stay local to each node.

### Testing

Stub conversions in tests, with no soffice running. See `URP.Test`.

```elixir
URP.Test.stub(fn _input, _opts -> {:ok, "%PDF-fake"} end)
assert {:ok, _} = MyApp.generate_invoice(order)
```

### Telemetry

Every operation is a `[:urp, :call, _]` span whose stop event carries queue
and service time. A connection that could not connect emits
`[:urp, :connection, :retry]`, and one that finished a job after its caller
stopped waiting emits `[:urp, :connection, :drain]`. See `URP.Telemetry`.

## Development

`mix test` runs the unit suite, which needs no soffice. Everything CI runs,
including the integration suite against LibreOffice from nixpkgs:

```sh
nix flake check
```

Or run the integration suite yourself, against LibreOffice from nixpkgs
listening on `PORT`, 2002 by default:

```sh
nix run .#soffice &
nix develop --command mix test --include integration
```

## Performance

See [PERFORMANCE.md](PERFORMANCE.md) for what a conversion does call by call, how long
it takes, and the scripts that measure both.

## References

- [UNO Binary Protocol Spec](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol)
- [binaryurp source](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/) — reader.cxx, writer.cxx, marshal.cxx
- [Export filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)

## Releasing

From a clean `main` that matches `origin/main`, with `major`, `minor` or `patch`:

```sh
nix run .#release -- minor
```

It does what you would by hand:

1. Bump `VERSION` and rename the `[Unreleased]` section of `CHANGELOG.md` to
   `[vX.Y.Z] - YYYY-MM-DD`, with a new empty `[Unreleased]` above it.
2. Commit.
3. Push to `main`.

Once the tests pass, CI publishes the package and its docs to Hex and creates
the GitHub release. A release that failed before its tag was created can be
retried by running the CI workflow on `main`.

## License

MIT — see [LICENSE](LICENSE).
