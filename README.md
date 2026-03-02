# URP

Pure Elixir client for the [UNO Remote Protocol](https://wiki.openoffice.org/wiki/Uno/Binary/Spec/Protocol).
Converts documents by talking directly to `soffice` over a TCP socket —
no wrappers or sidecars needed.

## Why?

Existing approaches to LibreOffice integration —
[unoserver](https://github.com/unoconv/unoserver),
[Gotenberg](https://gotenberg.dev/),
Python UNO bindings — each add an intermediate layer with its own
deployment complexity and failure modes.

URP speaks the binary protocol directly over TCP to a `soffice`
process. No Python runtime, no wrapper services.

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

A running `soffice` process with a URP socket listener. Build from
`benchmarks/Dockerfile.soffice-debian` or use your own Debian/Ubuntu
image with LibreOffice installed:

```sh
docker build --tag soffice --file benchmarks/Dockerfile.soffice-debian benchmarks/
docker run --detach --name soffice --publish 2002:2002 soffice
```

> [!NOTE]
> Any image with `soffice` listening on a TCP socket works — including
> `libreofficedocker/alpine`. See [PERFORMANCE.md](PERFORMANCE.md) for
> trade-offs.

## Usage

A default pool connects to `localhost:2002` automatically:

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

Configure in `config/runtime.exs`:

```elixir
config :urp, :default,
  host: "soffice",
  port: 2002,
  pool_size: 1
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

See [PERFORMANCE.md](PERFORMANCE.md) for benchmarks against Gotenberg
and container image recommendations.

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
