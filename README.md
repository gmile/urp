# URP

[![Hex.pm](https://img.shields.io/hexpm/v/urp.svg)](https://hex.pm/packages/urp)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/urp/readme.html)

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Talks directly to a `soffice` process over a TCP socket —
no Python, no wrappers, no sidecars.

## Why?

Existing approaches to LibreOffice integration —
[unoserver](https://github.com/unoconv/unoserver),
[Gotenberg](https://gotenberg.dev/),
Python UNO bindings — each add an intermediate layer with its own
deployment complexity and failure modes.

URP speaks the binary protocol directly over TCP. Document conversion
is the primary use case, but the same connection gives you access to
soffice diagnostics — registered services, available export filters,
document types, locale settings, and version info.

## Installation

Add `urp` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:urp, "~> 0.8"}
  ]
end
```

## Prerequisites

A running `soffice` process with a URP socket listener. Build from
`benchmarks/Dockerfile.soffice-debian` or use your own Debian/Ubuntu
image with LibreOffice installed:

```sh
docker build --tag soffice --file benchmarks/Dockerfile.soffice-debian benchmarks/
docker run --detach --name soffice --publish 2002:2002 soffice
```

> #### Note {: .info}
>
> Any image with `soffice` listening on a TCP socket works.
> See [PERFORMANCE.md](PERFORMANCE.md) for why Debian is recommended over Alpine.

## Usage

A default pool connects to `localhost:2002` automatically.

### Document conversion

```elixir
{:ok, pdf_path} =
  URP.convert("/path/to/input.docx",
    filter: "writer_pdf_Export",
    filter_data: [
      UseLosslessCompression: false,
      Quality: 90,
      ReduceImageResolution: true,
      MaxImageResolution: 150,
      ExportBookmarks: true,
      ExportFormFields: false
    ],
    output: "/tmp/output.pdf"
  )
```

Input can be a file path, `{:binary, bytes}`, or any `Enumerable`
(e.g. `File.stream!/2`). Output defaults to a temp file path; pass
an explicit path or `output: :binary` to get bytes in memory. See
[filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)
for all formats (`calc_pdf_Export`, `impress_pdf_Export`, etc.) and
[FilterData properties](https://wiki.documentfoundation.org/Macros/Python_Guide/PDF_export_filter_data)
for PDF export options.

### Diagnostics

```elixir
{:ok, "26.2.0.3"} = URP.version()
{:ok, services}   = URP.services()   # all registered UNO service names
{:ok, filters}    = URP.filters()    # available export filters
{:ok, types}      = URP.types()      # known document type names
{:ok, locale}     = URP.locale()     # soffice locale setting
```

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

## Telemetry

URP emits `:telemetry` events for observability. Every operation emits
`[:urp, :call, :stop]` with queue, service, and total time measurements.
See `URP.Telemetry` for event details, measurements, and metadata.

```elixir
:telemetry.attach("urp-logger", [:urp, :call, :stop], &MyApp.handle_urp_event/4, nil)
```

## Performance

See [PERFORMANCE.md](PERFORMANCE.md) for benchmarks against Gotenberg
and container image recommendations.

## Scope

Implements document conversion and read-only soffice introspection via UNO.
Export format is controlled by [filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)
(`writer_pdf_Export`, `calc_pdf_Export`, `impress_pdf_Export`, `Markdown`, etc.).
Mutating UNO APIs (editing, formatting, macros) are not implemented.

## Architecture

| Module | Role |
|---|---|
| `URP` | Public API — convert, diagnostics, test stubs |
| `URP.Telemetry` | Telemetry event documentation |
| `URP.Bridge` | Mid-level — UNO operations (handshake, convert, diagnostics, streaming) |
| `URP.Stream` | Bidirectional URP dispatch for XInputStream/XOutputStream |
| `URP.Protocol` | Low-level — binary wire format (framing, encoding, reply parsing) |

## References

- [UNO Binary Protocol Spec](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol)
- [binaryurp source](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/) — reader.cxx, writer.cxx, marshal.cxx
- [specialfunctionids.hxx](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/source/specialfunctionids.hxx)
- [typeclass.h](https://git.libreoffice.org/core/+/refs/heads/master/include/typelib/typeclass.h)
- [Export filter names](https://help.libreoffice.org/latest/en-US/text/shared/guide/convertfilters.html)

## Releasing

```sh
./release.sh patch   # or minor, major
git push origin main --tags
```

This bumps `VERSION`, stamps `CHANGELOG.md`, commits, and tags.
Pushing the tag triggers CI to publish to Hex automatically.

## License

MIT — see [LICENSE](LICENSE).

This is an independent implementation based on the public UNO protocol spec.
LibreOffice source was consulted as documentation for protocol details not
covered by the spec. No code was copied.
