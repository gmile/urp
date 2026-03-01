# Changelog

## [Unreleased]

- **Breaking:** unified API — single `URP.convert/2` replaces `convert_stream/2`, `convert_file_stream/2`, and `convert/3`
- **Breaking:** remove `URP.convert_stream/2`, `URP.convert_file_stream/2`, `URP.convert/3`, `URP.Pool.convert_stream/3`, `URP.Pool.convert_file_stream/3`, `URP.Pool.convert_url/4`
- **Breaking:** output destination is now `:output` option (path, `:binary`, or `fun/1`) instead of `:sink`
- **Breaking:** default output writes to temp file (returns `{:ok, path}`) instead of accumulating bytes in memory
- Add enumerable input support — pass any `Enumerable` (e.g. `File.stream!/2`, S3 download streams) to `URP.convert/2`
- Add `URP.Stream.start_enum_reader/1` and `URP.Bridge.load_document_enum_stream!/2` for lazy enumerable streaming

## [v0.4.0] - 2026-02-28

- **Breaking:** remove `use URP, otp_app: :my_app` macro — call `URP.convert_stream/2`, `URP.convert_file_stream/2`, `URP.convert/3` directly
- **Breaking:** `URP.Test.stub/1` replaces `URP.Test.stub/2` — stubs are global, no module name needed
- **Breaking:** remove `URP.Test.start/0` — ownership server starts automatically
- Add `URP.Application` — default pool, DynamicSupervisor, and ownership server start automatically
- Add named pools via `config :urp, :pools` — started on first use via DynamicSupervisor
- Handle soffice `DisposedException` with reactive retry on reconnect (matches C++ callers' approach)
- Make `nimble_ownership` a required dependency (no longer optional/test-only)

## [v0.3.1] - 2026-02-26

- Exclude `Mix.Tasks.Bump` from hex package to avoid module conflicts

## [v0.3.0] - 2026-02-26

- Fix protocol correctness: validate block count, support FUNCTIONID16/14, skip MOREFLAGS byte
- Fix one-way detection: use func_id (only `release` is one-way), not unreliable header flags
- Add `parse_exception/1` — extract human-readable messages from UNO exception replies
- Include exception details in error messages from `load_document!` and `store_to_url!`
- Add protocol unit tests (28 tests covering header parsing, encoding, reply classification)
- Add error handling integration tests
- Simplify `mix bump` task (remove network dependencies, fix editor hang with gpg signing)

## [v0.2.0] - 2026-02-26

- **Breaking:** remove `URP.Connection` — all calls go through `URP.Pool` via wrapper modules
- Make `use URP` route all calls through a supervised Pool
- Change default `pool_size` from 4 to 1 (matches single soffice instance)
- Rewrite README: clarify setup steps, explain function differences, add design tradeoffs
- Add Kubernetes scaling note
- Fail hard when soffice is not reachable in tests (instead of silently skipping)
- Hide `mix bump` from hexdocs

## [v0.1.2] - 2026-02-26

- Add `otp_app` config support for `URP.Pool`
- Add soffice service to CI for integration tests
- Add `:mix` to dialyzer PLT apps
- Add release workflow and `mix bump` task
- Remove stale `urp_convert.exs` script
- Fix license year

## [v0.1.1] - 2026-02-25

- Add streaming conversion via `XInputStream`/`XOutputStream` (no shared filesystem needed)
- Add file-backed streaming (`convert_file_stream/2`)
- Add sink option for streaming output to file or callback
- Add `URP.Pool` (NimblePool) for connection pooling
- Add `use URP` macro and `URP.Test` for stubbable wrapper modules
- Add typespecs to all public functions
- Add Nix flake dev shell
- Add dialyzer
- Make README the main page on hexdocs

## [v0.1.0] - 2026-02-25

- Initial release
