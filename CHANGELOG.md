# Changelog

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
