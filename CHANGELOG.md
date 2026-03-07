# Changelog

## [Unreleased]

- **New `:settings` option for `URP.convert/2`:** pass `{path, property, value}`
  triplets to configure soffice via `ConfigurationUpdateAccess` before each
  conversion. Settings sharing the same nodepath are batched into a single
  update call. Useful for tuning cache limits, graphic memory, etc.
- **Infinite reconnection with backoff:** the pool now retries soffice
  connections forever with exponential backoff (`backoff_initial` / `backoff_max`)
  instead of crashing. Emits `[:urp, :connection, :retry]` telemetry on each
  retry attempt.
- **Iodata frame builders:** `Call` and `Protocol` functions return iodata
  (lists of binaries) instead of flattened binaries. The single `IO.iodata_to_binary`
  call happens in `Protocol.send_frame/2`, eliminating redundant intermediate
  allocations.
- **Fix O(n²) `fill_buffer` in enum streams:** chunk accumulation now uses
  iodata instead of repeated binary concatenation, flattening once when the
  buffer is consumed.
- **Frame size guard:** `recv_frame` rejects frames larger than 512 MiB
  (configurable) before allocating, preventing OOM from corrupt wire data.
- **New `:recv_timeout` and `:max_frame_size` options for `URP.convert/2`:**
  per-conversion control over the TCP recv timeout (default 120 s) and maximum
  accepted frame size (default 512 MiB).
- **New `:io` option for `URP.convert/2`:** choose between file-based (`:file`,
  default) and streaming (`:stream`) I/O independently for input and output.
  File I/O uses temp files on soffice's filesystem (~6 round-trips). Streaming
  uses XInputStream/XOutputStream over URP (~40-50% slower but no temp disk).
  Mixed modes supported: `io: {:file, :stream}` or `io: {:stream, :file}`.
- **Fix TID cache loss across conversions:** the URP type cache accumulated
  during each conversion is now persisted back to the connection struct,
  preventing type desync on subsequent operations.
- **Fix large file conversion (>64 MB output):** `gen_tcp.recv` returns
  `:enomem` for single reads above ~64 MB. `recv_frame` now reads in 4 MB
  chunks and reassembles. Also eliminates redundant binary copies in
  `send_frame` (iodata passthrough) and `write_bytes` (new `enc_str_iodata/1`).
- **Fix stale `conn.reply` leaking as conversion result:** `conn.reply`
  retained values from bootstrap or diagnostic queries. Early conversion
  failures (e.g. file not found) could return stale data as a successful
  result. Convert now clears `conn.reply` on checkout and uses strict
  type-checked result matching.

## [v0.9.1] - 2026-03-06

- **Fix 2 GiB memory spike during conversion:** `read_file/2` now calls
  `available()` to get the exact output size before `readBytes()`. Previously
  it passed `0x7FFFFFFF` (2 GiB), causing soffice to pre-allocate a 2 GiB
  buffer on every conversion regardless of actual PDF size. Peak soffice RSS
  drops from ~2.3 GB to ~300 MB.

## [v0.9.0] - 2026-03-04

- Add `:telemetry` events — every pool operation emits `[:urp, :call, :stop]`
  with `queue_time`, `service_time`, and `total_time` measurements.
  See `URP.Telemetry` for details.

## [v0.8.1] - 2026-03-03

Internal refactor of Bridge and Pool internals. No public API changes.

- **Plug-like error handling:** Bridge functions no longer raise — errors
  accumulate on `conn.error` and short-circuit subsequent calls via guards.
  This replaces 13+ rescue blocks with a single, predictable data-flow pattern.
  Callers piping through Bridge get clean error propagation without try/rescue.
- **Uniform return type:** All Bridge functions return `t()`. Functions that
  previously returned tuples (`store_document_write`, `store_to_stream`,
  `read_file`) now stash results in `conn.reply`, enabling consistent piping.
- **Pool memory fix:** `reset_conversion_state` now clears `conn.reply`,
  preventing large binaries from being held between conversions.
- **Accurate type specs:** Bridge struct fields (`sock`, `desktop_oid`,
  `ctx_oid`, `smgr_oid`) now correctly typed as `| nil`; `reply` is `term()`.
- **CI: Debian soffice 26.2** with Docker layer caching — replaces Alpine
  image, enables LO 26.2+ tests (markdown export).
- Expanded test coverage: bang variants, Bridge-level `store_to_stream`,
  temp file cleanup.

## [v0.8.0] - 2026-03-02

- Add `URP.services/1` — list all registered UNO service names
- Add `URP.filters/1` — list all export filter names (discover available filters at runtime)
- Add `URP.types/1` — list all document type names
- Add `URP.locale/1` — query soffice locale setting
- Add `Protocol.parse_string_sequence_reply/1` for `sequence<string>` replies
- Add Diagnostics section to module docs with examples

## [v0.7.0] - 2026-03-02

- **File-based I/O:** load and store documents via XSimpleFileAccess instead of
  XInputStream/XOutputStream streaming — eliminates thousands of TCP round-trips
  per conversion, ~8x faster for typical documents
- **Breaking:** `close_document!/2` now returns `t()` instead of `{binary(), t()}`
- **Pipeline-friendly Bridge helpers** — all conn-threading helpers (`call`, `sfa_call`, `qi`)
  return just `conn`; enables `conn |> qi(...) |> call(...)` style
- Add `last_reply` and `last_error` fields to Bridge conn for introspection/debugging
- Add `:filter_data` option for export-specific settings
  (e.g. `[UseLosslessCompression: true, ExportFormFields: false]` for PDF)
- Add XSeekable support — ZIP-based formats (docx, xlsx, pptx, odt) stream
  without buffering the entire file first
- Reuse connections across conversions (no reconnect per document)
- Pre-compute static URP frame bodies at compile time
- Fix TID cache for cross-thread XSeekable replies
- Replace inline magic numbers with named constants throughout
- Add PERFORMANCE.md with benchmarks and container recommendations
- Add Benchee benchmark suite
- Switch Docker images to libreoffice-*-nogui packages

## [v0.6.1] - 2026-03-01

- Add `URP.version/1` — query soffice version string over URP (no CLI access needed)
- Hide URP.Pool from hex docs (internal module)
- Simplify README

## [v0.6.0] - 2026-03-01

- **Breaking:** `:filter` option is now required — no default export filter
- Remove PDF-centric language from docs — URP is a generic document conversion tool

## [v0.5.0] - 2026-03-01

- **Breaking:** unified API — single `URP.convert/2` replaces convert_stream/2, convert_file_stream/2, and convert/3
- **Breaking:** remove URP.convert_stream/2, URP.convert_file_stream/2, URP.convert/3, URP.Pool.convert_stream/3, URP.Pool.convert_file_stream/3, URP.Pool.convert_url/4
- **Breaking:** output destination is now `:output` option (path, `:binary`, or `fun/1`) instead of `:sink`
- **Breaking:** default output writes to temp file (returns `{:ok, path}`) instead of accumulating bytes in memory
- Add enumerable input support — pass any `Enumerable` (e.g. `File.stream!/2`, S3 download streams) to `URP.convert/2`
- Add `URP.Stream.start_enum_reader/1` and `URP.Bridge.load_document_enum_stream!/2` for lazy enumerable streaming

## [v0.4.0] - 2026-02-28

- **Breaking:** remove `use URP, otp_app: :my_app` macro — call URP.convert_stream/2, URP.convert_file_stream/2, URP.convert/3 directly
- **Breaking:** `URP.Test.stub/1` replaces URP.Test.stub/2 — stubs are global, no module name needed
- **Breaking:** remove URP.Test.start/0 — ownership server starts automatically
- Add URP.Application — default pool, DynamicSupervisor, and ownership server start automatically
- Add named pools via `config :urp, :pools` — started on first use via DynamicSupervisor
- Handle soffice DisposedException with reactive retry on reconnect (matches C++ callers' approach)
- Make nimble_ownership a required dependency (no longer optional/test-only)

## [v0.3.1] - 2026-02-26

- Exclude Mix.Tasks.Bump from hex package to avoid module conflicts

## [v0.3.0] - 2026-02-26

- Fix protocol correctness: validate block count, support FUNCTIONID16/14, skip MOREFLAGS byte
- Fix one-way detection: use func_id (only `release` is one-way), not unreliable header flags
- Add `parse_exception/1` — extract human-readable messages from UNO exception replies
- Include exception details in error messages from `load_document!` and `store_to_url!`
- Add protocol unit tests (28 tests covering header parsing, encoding, reply classification)
- Add error handling integration tests
- Simplify mix bump task (remove network dependencies, fix editor hang with gpg signing)

## [v0.2.0] - 2026-02-26

- **Breaking:** remove URP.Connection — all calls go through URP.Pool via wrapper modules
- Make `use URP` route all calls through a supervised Pool
- Change default pool_size from 4 to 1 (matches single soffice instance)
- Rewrite README: clarify setup steps, explain function differences, add design tradeoffs
- Add Kubernetes scaling note
- Fail hard when soffice is not reachable in tests (instead of silently skipping)
- Hide mix bump from hexdocs

## [v0.1.2] - 2026-02-26

- Add otp_app config support for URP.Pool
- Add soffice service to CI for integration tests
- Add `:mix` to dialyzer PLT apps
- Add release workflow and mix bump task
- Remove stale urp_convert.exs script
- Fix license year

## [v0.1.1] - 2026-02-25

- Add streaming conversion via XInputStream/XOutputStream (no shared filesystem needed)
- Add file-backed streaming (convert_file_stream/2)
- Add sink option for streaming output to file or callback
- Add URP.Pool (NimblePool) for connection pooling
- Add `use URP` macro and `URP.Test` for stubbable wrapper modules
- Add typespecs to all public functions
- Add Nix flake dev shell
- Add dialyzer
- Make README the main page on hexdocs

## [v0.1.0] - 2026-02-25

- Initial release
