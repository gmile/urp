defmodule URP.Protocol do
  @moduledoc """
  Low-level URP (UNO Remote Protocol) binary wire format.

  Handles framing, encoding, decoding, and reply parsing for the
  binaryurp protocol used by LibreOffice's `soffice` process.

  ## References

    * [binaryurp source](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/)
    * [typeclass.h](https://git.libreoffice.org/core/+/refs/heads/master/include/typelib/typeclass.h)
    * [specialfunctionids.hxx](https://git.libreoffice.org/core/+/refs/heads/master/binaryurp/source/specialfunctionids.hxx)
  """

  import Bitwise

  # Header flags — binaryurp/source/reader.cxx, writer.cxx
  @longheader 0x80
  @request 0x40
  @newtype 0x20
  @newoid 0x10
  @newtid 0x08
  @functionid16 0x04

  # reply-specific, shares bit 5 with @newtype
  @exception 0x20

  # UNO TypeClass — include/typelib/typeclass.h
  @tc_string 12
  @tc_interface 22

  # ORed into type class byte for uncached types
  @tc_new 0x80
  @tc_void 0

  @recv_timeout 120_000

  # Safety cap for incoming frame size — prevents OOM from corrupt streams
  @max_frame_size 512 * 1024 * 1024

  ## Frame I/O

  @doc "Send a single URP block: `<<size::32, count::32, payload>>`."
  @spec send_frame(:gen_tcp.socket(), iodata()) :: :ok
  def send_frame(sock, payload) do
    data = IO.iodata_to_binary(payload)
    :ok = :gen_tcp.send(sock, <<byte_size(data)::32, 1::32, data::binary>>)
  end

  @doc """
  Receive a single URP block, returning the payload.

  Raises if the block contains more than one message (the C++ writer always
  sends count=1, but the spec allows count>1).
  """
  @spec recv_frame(:gen_tcp.socket(), timeout(), pos_integer()) :: binary()
  def recv_frame(sock, timeout \\ @recv_timeout, max_frame_size \\ @max_frame_size) do
    {:ok, <<size::32, count::32>>} = :gen_tcp.recv(sock, 8, timeout)

    if count != 1 do
      raise "URP: received block with count=#{count}, expected 1 (multi-message blocks not supported)"
    end

    if size > max_frame_size do
      raise "URP: frame size #{size} exceeds #{max_frame_size} bytes (corrupt stream?)"
    end

    {:ok, payload} = :gen_tcp.recv(sock, size, timeout)
    payload
  end

  ## Request header builder

  @doc """
  Build a URP request header with automatic flag computation.

  Options:
    * `:type` — `{:new, type_name, cache_idx}` or `{:cached, cache_idx}`
    * `:oid`  — `{oid_string, cache_idx}`
    * `:tid`  — `{tid_bytes, cache_idx}`

  Omitting an option reuses the value from the previous message on the wire.
  """
  @spec request(non_neg_integer(), keyword()) :: binary()
  def request(func_id, opts \\ []) do
    flags = @longheader ||| @request

    {flags, type_part} =
      case opts[:type] do
        nil ->
          {flags, <<>>}

        {:cached, cache} ->
          {flags ||| @newtype, <<@tc_interface, cache::16>>}

        {:new, name, cache} ->
          {flags ||| @newtype, <<@tc_interface ||| @tc_new, cache::16>> <> enc_str(name)}
      end

    {flags, oid_part} =
      case opts[:oid] do
        nil -> {flags, <<>>}
        {oid_str, cache} -> {flags ||| @newoid, enc_str(oid_str) <> <<cache::16>>}
      end

    {flags, tid_part} =
      case opts[:tid] do
        nil -> {flags, <<>>}
        {tid_bytes, cache} -> {flags ||| @newtid, enc_str(tid_bytes) <> <<cache::16>>}
      end

    <<flags, func_id>> <> type_part <> oid_part <> tid_part
  end

  @doc "Build a void reply (LONGHEADER only)."
  @spec reply() :: binary()
  def reply, do: <<@longheader>>

  @doc "Build a reply with body."
  @spec reply(binary()) :: binary()
  def reply(body), do: <<@longheader>> <> body

  @doc "Build a void reply with explicit TID (for cross-thread replies)."
  @spec reply_with_tid(binary()) :: binary()
  def reply_with_tid(tid) when is_binary(tid),
    do: <<@longheader ||| @newtid>> <> enc_str(tid) <> <<0xFFFF::16>>

  @doc "Build a reply with body and explicit TID (for cross-thread replies)."
  @spec reply_with_tid(binary(), binary()) :: binary()
  def reply_with_tid(body, tid) when is_binary(tid),
    do: <<@longheader ||| @newtid>> <> enc_str(tid) <> <<0xFFFF::16>> <> body

  ## Compressed string encoding — binaryurp/source/marshal.cxx

  @doc "Encode a string with URP compressed-length prefix."
  @spec enc_str(binary()) :: binary()
  def enc_str(s) when byte_size(s) < 0xFF, do: <<byte_size(s), s::binary>>
  def enc_str(s), do: <<0xFF, byte_size(s)::32, s::binary>>

  @doc "Decode a compressed string, returning `{string, rest}`."
  @spec dec_str(binary()) :: {binary(), binary()}
  def dec_str(<<0xFF, len::32, s::binary-size(len), rest::binary>>), do: {s, rest}
  def dec_str(<<len, s::binary-size(len), rest::binary>>), do: {s, rest}

  ## Null CurrentContext — prefix on every request body after handshake

  @doc "Null CurrentContext reference: empty OID (0x00) + cache sentinel (0xFFFF)."
  @spec null_ctx() :: binary()
  def null_ctx, do: <<0x00, 0xFF, 0xFF>>

  ## Type parameters for queryInterface body

  @doc "Reference a type already in the peer's cache."
  @spec type_cached(non_neg_integer()) :: binary()
  def type_cached(cache_idx), do: <<@tc_interface, cache_idx::16>>

  @doc "Register a new interface type in the peer's cache."
  @spec type_new(String.t(), non_neg_integer()) :: iodata()
  def type_new(name, cache_idx) do
    [<<@tc_interface ||| @tc_new, cache_idx::16>>, enc_str(name)]
  end

  ## UNO PropertyValue struct — Name(string) + Handle(int32) + Value(any) + State(int32)

  @doc "Encode a UNO PropertyValue struct."
  @spec property(String.t(), non_neg_integer(), iodata()) :: iodata()
  def property(name, type_class, value_bytes) do
    [enc_str(name), <<0::32, type_class>>, value_bytes, <<0::32>>]
  end

  ## Incoming frame classification

  @doc """
  True if the frame is a reply (long header, no REQUEST flag).
  Everything else (long-header request or short-header) is a request.
  """
  @spec is_reply?(binary()) :: boolean()
  def is_reply?(<<flags, _::binary>>), do: (flags &&& 0xC0) == @longheader

  @doc """
  Parse an incoming request, extracting `func_id`, `body`, and `one_way` flag.

  Handles both long headers (LONGHEADER set, REQUEST set) and short headers
  (LONGHEADER not set — func_id in lower 6 bits, all cached values reused).

  `one_way` is true when the sender does not expect a reply (MOREFLAGS absent
  or MUSTREPLY not set). One-way calls like `release` must not receive replies.
  """
  @spec parse_request(binary()) :: %{
          func_id: non_neg_integer(),
          body: binary(),
          type_cache: non_neg_integer() | nil,
          tid: binary() | nil
        }
  def parse_request(<<flags, rest::binary>>) when (flags &&& @longheader) != 0 do
    # Long header — skip optional flags2, then extract func_id and skip header fields
    rest =
      if (flags &&& 0x01) != 0 do
        <<_flags2, r::binary>> = rest
        r
      else
        rest
      end

    # FUNCTIONID16 (bit 2): if set, func_id is uint16; otherwise uint8
    {func_id, rest} =
      if (flags &&& @functionid16) != 0 do
        <<fid::16, r::binary>> = rest
        {fid, r}
      else
        <<fid, r::binary>> = rest
        {fid, r}
      end

    {type_cache, rest} =
      if (flags &&& @newtype) != 0 do
        <<tc, cache::16, rest::binary>> = rest
        rest = if (tc &&& @tc_new) != 0, do: elem(dec_str(rest), 1), else: rest
        {cache, rest}
      else
        {nil, rest}
      end

    rest =
      if (flags &&& @newoid) != 0 do
        {_oid, rest} = dec_str(rest)
        <<_cache::16, rest::binary>> = rest
        rest
      else
        rest
      end

    {tid, rest} =
      if (flags &&& @newtid) != 0 do
        {tid_bytes, rest} = dec_str(rest)
        <<cache::16, rest::binary>> = rest

        tid =
          if tid_bytes == "" do
            # Cached TID — look up from our read cache
            tid_cache = Process.get(:urp_tid_cache, %{})
            Map.get(tid_cache, cache, tid_bytes)
          else
            # New TID — store in our read cache if cache index is valid
            if cache != 0xFFFF do
              tid_cache = Process.get(:urp_tid_cache, %{})
              Process.put(:urp_tid_cache, Map.put(tid_cache, cache, tid_bytes))
            end

            tid_bytes
          end

        {tid, rest}
      else
        {nil, rest}
      end

    %{func_id: func_id, body: rest, type_cache: type_cache, tid: tid}
  end

  def parse_request(<<header, rest::binary>>) do
    # Short header — reuses all cached values (including type).
    #
    # Bit 6 (0x40) = FUNCTIONID14: if set, func_id is 14-bit (bits[5:0] << 8 | next byte).
    # If clear, func_id is 6-bit (bits[5:0]).
    if (header &&& 0x40) != 0 do
      <<lo, body::binary>> = rest
      %{func_id: (header &&& 0x3F) <<< 8 ||| lo, body: body, type_cache: nil, tid: nil}
    else
      %{func_id: header &&& 0x3F, body: rest, type_cache: nil, tid: nil}
    end
  end

  @doc """
  True if the given func_id is `release` (one-way, no reply expected).

  Per the URP spec, `release` (func_id 2) is the only one-way call we'll
  encounter from soffice. Sending a reply to a one-way call is a protocol
  violation.
  """
  @spec one_way?(non_neg_integer()) :: boolean()
  def one_way?(2), do: true
  def one_way?(_), do: false

  ## Reply parsing

  @doc "Parse a queryInterface reply — extracts OID from `any(XInterface)` return value."
  @spec parse_qi_reply(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_qi_reply(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      {:error, parse_exception(payload)}
    else
      case rest do
        <<@tc_void, _::binary>> ->
          {:error, "queryInterface returned void"}

        <<tc, _ci::16, rest::binary>> ->
          rest = if (tc &&& @tc_new) != 0, do: elem(dec_str(rest), 1), else: rest
          {:ok, elem(dec_str(rest), 0)}
      end
    end
  end

  @doc "Parse a reply returning a single interface reference (OID string)."
  @spec parse_interface_reply(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_interface_reply(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      {:error, parse_exception(payload)}
    else
      {oid, _} = dec_str(rest)
      if oid == "", do: {:error, "empty OID"}, else: {:ok, oid}
    end
  end

  @doc "Parse a reply returning `any(string)` — extracts the string value."
  @spec parse_any_string_reply(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def parse_any_string_reply(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      {:error, parse_exception(payload)}
    else
      <<@tc_string, rest::binary>> = rest
      {value, _} = dec_str(rest)
      {:ok, value}
    end
  end

  @doc "Parse a reply returning a single signed 32-bit integer."
  @spec parse_int32_reply(binary()) :: {:ok, integer()} | {:error, String.t()}
  def parse_int32_reply(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      {:error, parse_exception(payload)}
    else
      <<value::32-signed, _::binary>> = rest
      {:ok, value}
    end
  end

  @doc "Parse a readBytes reply — return value (long) + out param (sequence<byte>)."
  @spec parse_read_bytes_reply(binary()) :: {:ok, binary()} | {:error, String.t()}
  def parse_read_bytes_reply(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      {:error, parse_exception(payload)}
    else
      <<_bytes_read::32-signed, rest::binary>> = rest
      {data, _} = dec_str(rest)
      {:ok, data}
    end
  end

  @doc "Parse a reply returning `sequence<string>`."
  @spec parse_string_sequence_reply(binary()) :: {:ok, [String.t()]} | {:error, String.t()}
  def parse_string_sequence_reply(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      {:error, parse_exception(payload)}
    else
      {count, rest} = dec_count(rest)
      {:ok, dec_strings(rest, count, [])}
    end
  end

  @doc """
  Extract a human-readable error message from an exception reply.

  UNO exceptions are `Any` values containing a struct. The first member
  of all exception structs is `Message` (string). Returns the message
  string, or a fallback if parsing fails.
  """
  @spec parse_exception(binary()) :: String.t() | nil
  def parse_exception(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      # Exception body: Any(type + struct). Skip type encoding to reach
      # the struct whose first member is always Message (string).
      try do
        <<tc, rest::binary>> = rest

        rest =
          if tc > 14 do
            <<_cache::16, rest::binary>> = rest
            if (tc &&& @tc_new) != 0, do: elem(dec_str(rest), 1), else: rest
          else
            rest
          end

        {message, _} = dec_str(rest)
        message
      rescue
        MatchError -> "UNO exception (could not parse message)"
      end
    end
  end

  defp skip_reply_header(<<flags, rest::binary>>) do
    rest =
      if (flags &&& @newtid) != 0 do
        {tid_bytes, rest} = dec_str(rest)
        <<cache::16, rest::binary>> = rest

        # Maintain TID read cache (shared with parse_request)
        if tid_bytes != "" and cache != 0xFFFF do
          tid_cache = Process.get(:urp_tid_cache, %{})
          Process.put(:urp_tid_cache, Map.put(tid_cache, cache, tid_bytes))
        end

        rest
      else
        rest
      end

    {flags, rest}
  end

  defp dec_count(<<0xFF, count::32, rest::binary>>), do: {count, rest}
  defp dec_count(<<count, rest::binary>>), do: {count, rest}

  defp dec_strings(_rest, 0, acc), do: Enum.reverse(acc)

  defp dec_strings(rest, n, acc) do
    {s, rest} = dec_str(rest)
    dec_strings(rest, n - 1, [s | acc])
  end
end
