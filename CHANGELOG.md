# Changelog

## [v0.1.1] - 2026-02-25

- Add streaming conversion via `XInputStream`/`XOutputStream` (no shared filesystem needed)
- Add file-backed streaming (`convert_file_stream/2`)
- Add sink option for streaming output to file or callback
- Add `URP.Connection` GenServer for serialized access
- Add `URP.Pool` (NimblePool) for concurrent conversions
- Add `use URP` macro and `URP.Test` for stubbable wrapper modules
- Add typespecs to all public functions
- Add Nix flake dev shell
- Add dialyzer
- Make README the main page on hexdocs

## [v0.1.0] - 2026-02-25

- Initial release
