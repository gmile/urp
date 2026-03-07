# Performance issues to address

## 1. Single-shot `read_bytes` for large outputs

**Location:** `bridge.ex:read_file/2`, `call.ex:read_bytes/1`

After the `available()` fix, we pass the exact file size to `readBytes()`. This is correct
but still single-shot: a 500 MB PDF means a 500 MB allocation on soffice's side, a 500 MB
URP frame over TCP, and a 500 MB binary in the BEAM — all at once.

**Fix:** Read in a loop with reasonable chunks (e.g. 1 MB), accumulating into iodata.
Low priority since the streaming path (`store_to_stream`) exists for large outputs.

## 2. Default output accumulation in `recv_handling_output`

**Location:** `stream.ex:recv_handling_output/2`

When `store_to_stream()` is called without a `sink` option, all output chunks accumulate
in a list (`{:mem, [...]}`), then get materialized with `IO.iodata_to_binary()` in
`finalize_sink/1`. For large PDFs this means the entire output lives in memory twice
momentarily (as iodata list + as binary).

**Fix:** Document that `sink: {:path, path}` or `sink: fun/1` should be used for large
outputs. Consider a size-based warning or automatic switch to temp file.

## 3. O(n^2) binary concatenation in `fill_buffer`

**Location:** `stream.ex:fill_buffer/3`

`buffer <> data` in a loop copies the entire buffer on each append. With many small chunks
from a fine-grained Enumerable (e.g. 4 KB chunks from `File.stream!/2`), this is O(n^2).

**Fix:** Accumulate as iodata list (`[data | buffer]`), reverse + materialize only when
the caller needs a contiguous binary.

## 4. No frame size safety check

**Location:** `protocol.ex:recv_frame/2`

`gen_tcp.recv(sock, size)` accepts whatever size soffice reports in the frame header.
A malfunctioning soffice (or corrupt TCP stream) could report a multi-gigabyte frame,
causing an enormous allocation.

**Fix:** Add a sanity cap (e.g. 512 MB) — error with a clear message if exceeded.
