# Req-style API refactor

## Problem

Test code (`URP.Test.__fetch_stub__/1`) runs on every production call. The `use URP, otp_app: :my_app` macro generates thin wrappers that users must add to their supervision tree. This coupling can be eliminated by following Req's architecture: library manages its own infrastructure, config drives behavior.

## Design

### Architecture

`URP.Application` starts three children:

1. **`URP.Pool` (default)** — NimblePool connecting to `localhost:2002` (configurable via `config :urp, host:, port:, pool_size:`)
2. **`DynamicSupervisor`** — for named pools started on first use
3. **`NimbleOwnership`** — test stub registry (unconditional, like Req)

### Public API

Everything goes through a pool. No direct-connection path.

```elixir
URP.convert_stream(bytes)                                  # default pool
URP.convert_stream(bytes, pool: :spreadsheets)             # named pool
URP.convert_stream(bytes, sink: {:path, "/tmp/out.pdf"})   # with options
URP.convert_file_stream(path)                              # same patterns
URP.convert_file_stream(path, pool: :spreadsheets)
URP.convert(input_path, output_path)                       # same patterns
URP.convert(input_path, output_path, pool: :spreadsheets)
```

### Named pools

Started on first use via DynamicSupervisor. Config provides connection details:

```elixir
config :urp, :pools,
  spreadsheets: [host: "soffice-2", port: 2002, pool_size: 3]
```

When `URP.convert_stream(bytes, pool: :spreadsheets)` is called:
1. Check if pool process exists
2. If not, read config from `:urp, :pools, :spreadsheets`
3. Start pool under DynamicSupervisor
4. Route conversion through it

### Testing

```elixir
# In tests — no setup needed, ownership server starts with the app
URP.Test.stub(fn _input, _opts -> {:ok, "fake pdf"} end)

# Allow child processes
URP.Test.allow(self(), worker_pid)
```

Stub check happens in `URP` module functions before pool dispatch. When no stub is registered, `NimbleOwnership.fetch_owner` returns `:error` quickly (same as Req).

### Config

```elixir
# config/runtime.exs
config :urp,
  host: "soffice",
  port: 2002,
  pool_size: 1

# Named pools (optional)
config :urp, :pools,
  spreadsheets: [host: "soffice-2", port: 2002, pool_size: 3]
```

### What goes away

- `use URP, otp_app: :my_app` macro
- User-defined converter modules (`MyApp.Converter`)
- User adding converter to supervision tree
- `URP.Test.start()` in test_helper.exs
- Direct-connection functions (no-pool path)

### What stays (unchanged)

- `URP.Pool` — same NimblePool implementation, started by URP.Application instead of user
- `URP.Bridge` — TCP connection and UNO operations
- `URP.Stream` — XInputStream/XOutputStream dispatch
- `URP.Protocol` — binary wire format

### Module responsibilities

| Module | Role |
|---|---|
| `URP` | Public API — stub check, pool dispatch |
| `URP.Application` | Starts default pool + DynamicSupervisor + ownership server |
| `URP.Pool` | NimblePool — connection pooling and Bridge lifecycle |
| `URP.Test` | Test stubs via NimbleOwnership |
| `URP.Bridge` | Mid-level UNO operations (handshake, load, store, close) |
| `URP.Stream` | Bidirectional dispatch for XInputStream/XOutputStream |
| `URP.Protocol` | Binary wire format (framing, encoding, reply parsing) |
