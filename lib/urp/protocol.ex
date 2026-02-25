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
  @request    0x40
  @newtype    0x20
  @newoid     0x10
  @newtid     0x08
  @exception  0x20 # reply-specific, shares bit 5 with @newtype

  # UNO TypeClass — include/typelib/typeclass.h
  @tc_interface 22
  @tc_new       0x80 # ORed into type class byte for uncached types
  @tc_void      0

  @recv_timeout 120_000

  ## Frame I/O

  @doc "Send a single URP block: `<<size::32, count::32, payload>>`."
  def send_frame(sock, payload) do
    data = IO.iodata_to_binary(payload)
    :ok = :gen_tcp.send(sock, <<byte_size(data)::32, 1::32, data::binary>>)
  end

  @doc "Receive a single URP block, returning the payload."
  def recv_frame(sock, timeout \\ @recv_timeout) do
    {:ok, <<size::32, _count::32>>} = :gen_tcp.recv(sock, 8, timeout)
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
  def request(func_id, opts \\ []) do
    flags = @longheader ||| @request

    {flags, type_part} =
      case opts[:type] do
        nil ->
          {flags, <<>>}

        {:cached, cache} ->
          {flags ||| @newtype, <<@tc_interface, cache::16>>}

        {:new, name, cache} ->
          {flags ||| @newtype, <<(@tc_interface ||| @tc_new), cache::16>> <> enc_str(name)}
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
  def reply, do: <<@longheader>>

  @doc "Build a reply with body."
  def reply(body), do: <<@longheader>> <> body

  ## Compressed string encoding — binaryurp/source/marshal.cxx

  @doc "Encode a string with URP compressed-length prefix."
  def enc_str(s) when byte_size(s) < 0xFF, do: <<byte_size(s), s::binary>>
  def enc_str(s), do: <<0xFF, byte_size(s)::32, s::binary>>

  @doc "Decode a compressed string, returning `{string, rest}`."
  def dec_str(<<0xFF, len::32, s::binary-size(len), rest::binary>>), do: {s, rest}
  def dec_str(<<len, s::binary-size(len), rest::binary>>), do: {s, rest}

  ## Null CurrentContext — prefix on every request body after handshake

  @doc "Null CurrentContext reference: empty OID (0x00) + cache sentinel (0xFFFF)."
  def null_ctx, do: <<0x00, 0xFF, 0xFF>>

  ## Type parameters for queryInterface body

  @doc "Reference a type already in the peer's cache."
  def type_cached(cache_idx), do: <<@tc_interface, cache_idx::16>>

  @doc "Register a new interface type in the peer's cache."
  def type_new(name, cache_idx) do
    <<(@tc_interface ||| @tc_new), cache_idx::16>> <> enc_str(name)
  end

  ## UNO PropertyValue struct — Name(string) + Handle(int32) + Value(any) + State(int32)

  @doc "Encode a UNO PropertyValue struct."
  def property(name, type_class, value_bytes) do
    enc_str(name) <> <<0::32, type_class>> <> value_bytes <> <<0::32>>
  end

  ## Reply parsing

  @doc "Parse a queryInterface reply — extracts OID from `any(XInterface)` return value."
  def parse_qi_reply(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      nil
    else
      case rest do
        <<@tc_void, _::binary>> ->
          nil

        <<tc, _ci::16, rest::binary>> ->
          rest = if (tc &&& @tc_new) != 0, do: elem(dec_str(rest), 1), else: rest
          elem(dec_str(rest), 0)
      end
    end
  end

  @doc "Parse a reply returning a single interface reference (OID string)."
  def parse_interface_reply(payload) do
    {flags, rest} = skip_reply_header(payload)

    if (flags &&& @exception) != 0 do
      nil
    else
      {oid, _} = dec_str(rest)
      if oid == "", do: nil, else: oid
    end
  end

  defp skip_reply_header(<<flags, rest::binary>>) do
    rest =
      if (flags &&& @newtid) != 0 do
        {_tid, rest} = dec_str(rest)
        <<_cache::16, rest::binary>> = rest
        rest
      else
        rest
      end

    {flags, rest}
  end
end
