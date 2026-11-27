# Changelog

## [Unreleased]

The connection handling is rewritten. `URP.convert/2` and the diagnostics keep their shape, but
several options and behaviours change; every breaking one is marked.

### Changed

- **Each connection is a process that owns its socket and sees every job through.** A caller that
  stops waiting no longer takes the socket with it, so nothing is left half done in `soffice` and
  the connection goes on to its next job instead of being closed. A job in hand is finished when
  the application shuts down, too.
- A pool is a queue of jobs and the connections that take them, under one supervisor, in place of
  NimblePool. A connection asks for a job when it has nothing to do, so one that is busy,
  reconnecting or stuck is never handed one. Every pool, the default one included, starts on
  first use.
- A connection finds out that `soffice` went away while it was idle before running the next job,
  and reconnects first. That job used to fail with `:closed`.
- The i-th connection of a pool takes the i-th address its host resolves to. This replaces
  "the address the fewest connections hold".
- **Breaking:** `:recv_timeout` is gone, and `:timeout` is how long the caller waits for the
  result: for a connection to come free and then for the whole conversion. Waiting too long is
  `{:error, :timeout}` either way; waiting for a connection used to end in a
  `"pool checkout failed"` message.
- **Breaking:** the `:io` option, stream I/O and enumerable input are gone. A document is sent to
  `soffice` in one message and loaded from memory there, for every format; `soffice` had loaded an
  empty document from an enumerable, and from a stream of anything but a ZIP or OLE2 document.
  The result is read back in chunks through a temp file on its side, and the new `:chunk_size`
  pool option (default 1 MiB) sets their size.
- **Breaking:** `:output` is required. Without it the result went to a temp file that nothing
  ever deleted.
- **Breaking:** an `:output` function is called in the connection's process, not the caller's,
  with one chunk at a time.
- **Breaking:** the `:max_frame_size` option is gone; no message received is larger than a chunk.
- **Breaking:** options are checked with NimbleOptions, for the diagnostics as well. A bad option
  raises `NimbleOptions.ValidationError` where it raised `ArgumentError`, and an unknown one is
  an error too.
- **Breaking:** an atom reason now always means there was no answer to be had, and a string that
  this one job failed. A pool that is not running is `:unavailable`, and an exchange with
  `soffice` that went wrong is `:protocol_error`, with the details logged; both were strings.
- **Breaking:** the functions ending in `!` raise `URP.Error` for a string reason, where they
  raised `RuntimeError`.
- **Breaking:** `[:urp, :call, _]` is a `:telemetry.span/3`. `:total_time` is `:duration`, and
  `:backoff_time` and `:attempts` are gone along with the retry they measured. A call that times
  out is a `:stop` event with `result: :error` and neither `:queue_time` nor `:service_time`,
  since the caller cannot know how far it got.
- Only `URP`, `URP.Test`, `URP.Telemetry` and the two exceptions are documented. The modules
  under them were never supported API, and have been rewritten.

### Fixed

- Stop leaking a document in `soffice` each time a call outlives its timeout. `soffice` cannot be
  interrupted, so it finished the load after the connection was gone and kept the document, its
  lock file and its temp file for the life of the process, about 10 MB apiece. The caller still
  gets `{:error, :timeout}` right away; the connection waits for `soffice`, closes the document,
  deletes its temp files and takes its next job. If `soffice` says nothing for the new
  `:drain_timeout` pool option (default 5 minutes) the connection reconnects instead. Each such
  wait emits `[:urp, :connection, :drain]`.
- Release what a job opened when its caller is killed part way through.
- An `:output` function that raises, exits or throws fails that conversion and nothing else.
- Close the temp-file streams in `soffice` when a conversion fails part way through moving a
  document.

## [v0.12.0] - 2026-09-11

### Changed

- Spread pool workers across the addresses `host` resolves to, so a pool behind a headless
  Kubernetes service or a round-robin DNS name uses every soffice instance. A worker whose address
  drops out of DNS picks another on retry.

## [v0.11.0] - 2026-08-20

### Changed

- **Breaking:** report socket failures as atoms. A call that fails at the socket now returns
  `{:error, :timeout}`, `{:error, :closed}` or `{:error, <posix>}` where it previously returned
  a message string built from a `MatchError`, so callers can tell a `soffice` that stopped
  answering from a document it refused. Errors from `soffice` itself are still message strings;
  code that assumed every reason was a binary has to handle both.

### Fixed

- Raise `URP.SocketError` from `URP.Protocol` when a `:gen_tcp` send or recv fails, instead of
  failing a match and reporting the resulting `MatchError` message as the error.

## [v0.10.3] - 2026-08-03

### Fixed

- Report the real error when a conversion fails at the socket level, instead of returning the
  stale interface OID left in the reply as if it were the converted output.

## [v0.10.2] - 2026-07-14

### Changed

- Emit complete telemetry spans with start, stop, and exception events.
- Use the Nix flake as the Elixir/OTP source of truth in CI and release validation.
- Make LibreOffice integration tests an explicit opt-in instead of probing an ambient port.
- Clarify that multiple connections to one soffice process are supported but share state
  and generally do not provide useful conversion parallelism.

### Fixed

- Return errors from non-bang APIs when pool checkout fails and discard broken diagnostic workers.
- Scope URP TID and OID caches to individual connections and decode cached interface references.
- Preserve streamed input resources through export and bound enumerable input with demand-driven flow.
- Propagate stream export and output-sink failures instead of returning partial success.
- Run best-effort document and remote-temp cleanup after failed conversions.
- Restore per-call timeout and frame-size overrides before returning workers to the pool.
- Validate public conversion options before dispatching test stubs or protocol work.
- Harden release validation and make benchmarks reject failed or non-PDF results.

### Security

- Use unpredictable temporary names and run the benchmark LibreOffice image as a non-root user.
- Bind documented benchmark service ports to loopback by default.

## [v0.10.1] - 2026-07-14

### Changed

- Require Elixir 1.20 and validate the project and release flow on Erlang/OTP 29.
- Refresh project dependencies, development tooling, GitHub Actions, and benchmark results.
- Expand CI coverage to include dependency, cycle, documentation, Hex audit, Nix flake,
  Dialyzer, unit, and LibreOffice 26.2 integration checks.

### Fixed

- Allow pure unit tests to run without a local LibreOffice process.
- Remove the compile-time `URP.Bridge` ↔ `URP.Stream` module cycle.
- Resolve Elixir 1.20 compiler warnings in stream bitstring matching and bridge dispatch.

## [v0.10.0] - 2026-03-12

### Added

- **`:settings` option for `URP.convert/2`:** pass `{path, property, value}`
  triplets to configure soffice via `ConfigurationUpdateAccess` before each
  conversion. Settings sharing the same nodepath are batched into a single
  update call. Useful for tuning cache limits, graphic memory, etc.
- **`:io` option for `URP.convert/2`:** choose between file-based (`:file`,
  default) and streaming (`:stream`) I/O independently for input and output.
  File I/O uses temp files on soffice's filesystem (~6 round-trips). Streaming
  uses XInputStream/XOutputStream over URP (~40-50% slower but no temp disk).
  Mixed modes supported: `io: {:file, :stream}` or `io: {:stream, :file}`.
- **`:recv_timeout` and `:max_frame_size` options for `URP.convert/2`:**
  per-conversion control over the TCP recv timeout (default 120 s) and maximum
  accepted frame size (default 512 MiB).
- **Infinite reconnection with backoff:** the pool retries soffice connections
  forever with exponential backoff (`backoff_initial` / `backoff_max`) instead
  of crashing. Emits `[:urp, :connection, :retry]` telemetry on each attempt.
- **Frame size guard:** `recv_frame` rejects frames larger than 512 MiB
  (configurable) before allocating, preventing OOM from corrupt wire data.

### Fixed

- **Pool query checkin leak:** diagnostic queries (`version`, `services`, etc.)
  did not reset `conn.private`, `conn.reply`, or `conn.doc_oid` on checkin,
  leaking state across pool reuses. All pool operations now go through
  `reset_conversion_state/1`.
- **Default pool ignored backoff config:** `backoff_initial` and `backoff_max`
  from `config :urp, :default` were silently dropped. Application now forwards
  the full config map to the pool.
- **Large file conversion (>64 MB output):** `gen_tcp.recv` returns `:enomem`
  for single reads above ~64 MB. `recv_frame` now reads in 4 MB chunks and
  reassembles. Also eliminates redundant binary copies in `send_frame` (iodata
  passthrough) and `write_bytes` (`enc_str_iodata/1`).
- **Stale `conn.reply` leaking as conversion result:** `conn.reply` retained
  values from bootstrap or diagnostic queries. Early conversion failures (e.g.
  file not found) could return stale data as a successful result. Convert now
  clears `conn.reply` on checkout with strict type-checked result matching.
- **TID cache loss across conversions:** the URP type cache accumulated during
  each conversion is now persisted back to the connection struct, preventing
  type desync on subsequent operations.
- **O(n²) `fill_buffer` in enum streams:** chunk accumulation now uses iodata
  instead of repeated binary concatenation, flattening once when consumed.

### Changed

- **Iodata frame builders:** `Call` and `Protocol` return iodata instead of
  flattened binaries. The single `IO.iodata_to_binary` call happens in
  Protocol `send_frame/2`, eliminating redundant intermediate allocations.
- Bridge error paths use `reply: nil` instead of `reply: ""` for consistency.

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
- Add Protocol `parse_string_sequence_reply/1` for `sequence<string>` replies
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
- Add lazy enumerable streaming (enum reader + Bridge stream loader)

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
