defmodule URP.Protocol do
  @moduledoc false

  # The binary URP (UNO Remote Protocol) wire format: frames, message headers
  # and the handful of UNO types the client marshals.
  #
  # URP lets a message leave out its type, object or thread id to mean "same as
  # the previous message", and lets it refer to one by a numbered cache slot.
  # Outgoing messages use neither: every request names all three in full, so
  # nothing on our side has to remember what went before. soffice does use both
  # in what it sends, and `reader/0` is the state needed to follow it.
  #
  # Values are encoded and decoded against a type:
  #
  #   * `:void`, `:boolean`, `:long`, `:hyper`, `:string`
  #   * `:bytes` — `sequence<byte>`
  #   * `:type` — an interface type, as `queryInterface` takes it (encode only)
  #   * `{:interface, name}` — an object reference, held as its OID or `nil`
  #   * `{:sequence, type}`
  #   * `{:struct, name, [type]}` — a list of member values (encode only)
  #   * `:any` — a `{type, value}` pair when encoded. Decoding returns the bare
  #     value, and understands only what soffice answers with here: void,
  #     strings, numbers, booleans and object references.
  #
  # References: binaryurp/source/{reader,writer,marshal,unmarshal}.cxx and
  # include/typelib/typeclass.h in LibreOffice core.

  import Bitwise

  # Cache index meaning "do not cache this".
  @uncached 0xFFFF

  # ORed into a type class byte when the type's name follows.
  @named 0x80

  # UNO TypeClass — include/typelib/typeclass.h
  @classes %{
    void: 0,
    boolean: 2,
    long: 6,
    hyper: 8,
    string: 12,
    any: 14,
    struct: 17,
    sequence: 20,
    interface: 22
  }
  @void @classes.void
  @boolean @classes.boolean
  @long @classes.long
  @hyper @classes.hyper
  @string @classes.string
  @any @classes.any
  @interface @classes.interface

  # Any object reference, where the interface it is typed as does not matter.
  @object {:interface, "com.sun.star.uno.XInterface"}

  # No message comes near this: documents move a chunk at a time. A frame that
  # claims more is a corrupt stream.
  @max_frame_size 32 * 1024 * 1024

  @type type ::
          :void
          | :boolean
          | :long
          | :hyper
          | :string
          | :any
          | :bytes
          | :type
          | {:interface, String.t()}
          | {:sequence, type()}
          | {:struct, String.t(), [type()]}

  @typedoc "The types and objects `soffice` has put in numbered cache slots."
  @type reader :: %{
          types: %{non_neg_integer() => String.t()},
          oids: %{non_neg_integer() => String.t()}
        }

  @type message :: {:reply, binary()} | {:exception, String.t()} | {:request, non_neg_integer()}

  @spec reader() :: reader()
  def reader, do: %{types: %{}, oids: %{}}

  ## Frames

  @doc "Send a single URP block: `<<size::32, count::32, payload>>`."
  @spec send_frame(:gen_tcp.socket(), iodata()) :: :ok
  def send_frame(sock, payload) do
    case :gen_tcp.send(sock, [<<IO.iodata_length(payload)::32, 1::32>>, payload]) do
      :ok -> :ok
      {:error, reason} -> raise URP.SocketError, reason: reason
    end
  end

  @doc """
  Receive a single URP block, returning the payload.

  Raises `URP.SocketError` when the socket fails or nothing arrives within
  `timeout`.
  """
  @spec recv_frame(:gen_tcp.socket(), timeout()) :: binary()
  def recv_frame(sock, timeout) do
    case recv(sock, 8, timeout) do
      <<size::32, 1::32>> when size <= @max_frame_size -> recv(sock, size, timeout)
      header -> raise "URP: unreadable block header #{inspect(header)}"
    end
  end

  defp recv(_sock, 0, _timeout), do: <<>>

  defp recv(sock, size, timeout) do
    case :gen_tcp.recv(sock, size, timeout) do
      {:ok, payload} -> payload
      {:error, reason} -> raise URP.SocketError, reason: reason
    end
  end

  ## Outgoing requests

  @doc """
  The header of a request: function, interface type, object and thread, all
  spelled out and none of them cached.
  """
  @spec header(byte(), String.t(), String.t(), binary()) :: iodata()
  def header(function, type, oid, tid) do
    # A long header for a request that names a new type, object and thread.
    [
      <<1::1, 1::1, 1::1, 1::1, 1::1, 0::3, function>>,
      type_tag({:interface, type}),
      enc_str(oid),
      <<@uncached::16>>,
      enc_str(tid),
      <<@uncached::16>>
    ]
  end

  @doc "A request: header, null current context, then the encoded arguments."
  @spec request(byte(), String.t(), String.t(), binary(), [{type(), term()}]) :: iodata()
  def request(function, type, oid, tid, args) do
    [
      header(function, type, oid, tid),
      encode(@object, nil),
      for({type, value} <- args, do: encode(type, value))
    ]
  end

  ## Incoming messages

  @doc """
  Read the header of an incoming frame.

  A reply comes back as its undecoded body, to be read with `decode/3` against
  the type the request returns, or as the message of the exception it carries.
  A request comes back as the number of the function called; whatever its
  header put in a cache slot is remembered.
  """
  @spec decode_message(binary(), reader()) :: {message(), reader()}
  def decode_message(frame, reader)

  # Long header, reply: an exception flag and perhaps a thread id.
  def decode_message(<<1::1, 0::1, exception::1, _::1, tid::1, _::3, rest::binary>>, reader) do
    rest = skip_tid(tid, rest)
    if exception == 1, do: decode_exception(rest, reader), else: {{:reply, rest}, reader}
  end

  # Long header, request: each of type, object and thread is there if flagged.
  def decode_message(
        <<1::1, 1::1, type::1, oid::1, _tid::1, wide::1, _::1, more::1, rest::binary>>,
        reader
      ) do
    rest = binary_part(rest, more, byte_size(rest) - more)
    bits = if wide == 1, do: 16, else: 8
    <<function::size(^bits), rest::binary>> = rest

    {rest, reader} =
      if type == 1 do
        {_type, rest, reader} = dec_type(rest, reader)
        {rest, reader}
      else
        {rest, reader}
      end

    reader =
      if oid == 1 do
        {_oid, _rest, reader} = decode(@object, rest, reader)
        reader
      else
        reader
      end

    {{:request, function}, reader}
  end

  # Short header: the type, object and thread of the message before.
  def decode_message(<<0::1, 0::1, function::6, _::binary>>, reader) do
    {{:request, function}, reader}
  end

  def decode_message(<<0::1, 1::1, function::14, _::binary>>, reader) do
    {{:request, function}, reader}
  end

  defp skip_tid(0, rest), do: rest

  defp skip_tid(1, rest) do
    {_tid, <<_slot::16, rest::binary>>} = dec_str(rest)
    rest
  end

  # Every UNO exception starts with a message and the object that raised it.
  # What a derived exception adds cannot be read without its type description,
  # and is left: anything it would have cached is then unknown to us.
  defp decode_exception(rest, reader) do
    {{_class, name}, rest, reader} = dec_type(rest, reader)
    {message, rest} = dec_str(rest)
    {_context, _rest, reader} = decode(@object, rest, reader)
    {{:exception, if(message == "", do: name || "UNO exception", else: message)}, reader}
  end

  ## Values

  @doc "Encode `value` as `type`."
  @spec encode(type(), term()) :: iodata()
  def encode(:void, _value), do: []
  def encode(:boolean, value), do: if(value, do: <<1>>, else: <<0>>)
  def encode(:long, value), do: <<value::32-signed>>
  def encode(:hyper, value), do: <<value::64-signed>>
  def encode(:string, value), do: enc_str(value)
  def encode(:bytes, value), do: [enc_count(byte_size(value)), value]
  def encode(:type, name), do: type_tag({:interface, name})
  def encode(:any, {type, value}), do: [type_tag(type), encode(type, value)]
  def encode({:interface, _name}, nil), do: <<0, @uncached::16>>
  def encode({:interface, _name}, oid), do: [enc_str(oid), <<@uncached::16>>]

  def encode({:sequence, type}, values) do
    [enc_count(length(values)) | Enum.map(values, &encode(type, &1))]
  end

  def encode({:struct, _name, types}, values) do
    Enum.zip_with(types, values, &encode/2)
  end

  @doc """
  Decode a value of `type` from the front of `binary`.

  Returns the value, what is left of the binary, and the reader, which learns
  any type or object `soffice` cached along the way.
  """
  @spec decode(type(), binary(), reader()) :: {term(), binary(), reader()}
  def decode(:void, rest, reader), do: {nil, rest, reader}
  def decode(:boolean, <<value, rest::binary>>, reader), do: {value != 0, rest, reader}
  def decode(:long, <<value::32-signed, rest::binary>>, reader), do: {value, rest, reader}
  def decode(:hyper, <<value::64-signed, rest::binary>>, reader), do: {value, rest, reader}

  def decode(type, binary, reader) when type in [:string, :bytes] do
    {value, rest} = dec_str(binary)
    {value, rest, reader}
  end

  # An object reference is its OID with a slot to keep it in, or an empty OID
  # and the slot it was kept in. A null reference is empty and uncached.
  def decode({:interface, _name}, binary, reader) do
    case dec_str(binary) do
      {"", <<slot::16, rest::binary>>} -> {reader.oids[slot], rest, reader}
      {oid, <<@uncached::16, rest::binary>>} -> {oid, rest, reader}
      {oid, <<slot::16, rest::binary>>} -> {oid, rest, put_in(reader.oids[slot], oid)}
    end
  end

  def decode({:sequence, type}, binary, reader) do
    {count, rest} = dec_count(binary)

    {values, {rest, reader}} =
      Enum.map_reduce(1..count//1, {rest, reader}, fn _index, {rest, reader} ->
        {value, rest, reader} = decode(type, rest, reader)
        {value, {rest, reader}}
      end)

    {values, rest, reader}
  end

  def decode(:any, binary, reader) do
    {{class, _name}, rest, reader} = dec_type(binary, reader)

    case class do
      @void -> {nil, rest, reader}
      @boolean -> decode(:boolean, rest, reader)
      @long -> decode(:long, rest, reader)
      @hyper -> decode(:hyper, rest, reader)
      @string -> decode(:string, rest, reader)
      @interface -> decode(@object, rest, reader)
      other -> raise "URP: cannot decode an any holding type class #{other}"
    end
  end

  # A type is its class, and for anything past `any` a cache slot and, the
  # first time, its name. The slots are shared by headers and values alike.
  defp dec_type(<<class, rest::binary>>, reader) when class <= @any do
    {{class, nil}, rest, reader}
  end

  defp dec_type(<<1::1, class::7, slot::16, rest::binary>>, reader) do
    {name, rest} = dec_str(rest)
    reader = if slot == @uncached, do: reader, else: put_in(reader.types[slot], name)
    {{class, name}, rest, reader}
  end

  defp dec_type(<<class, slot::16, rest::binary>>, reader) do
    {{class, reader.types[slot]}, rest, reader}
  end

  defp type_tag({:interface, name}), do: named_tag(@interface, name)
  defp type_tag({:struct, name, _types}), do: named_tag(@classes.struct, name)
  defp type_tag({:sequence, _type} = type), do: named_tag(@classes.sequence, type_name(type))
  defp type_tag(type), do: <<Map.fetch!(@classes, type)>>

  defp named_tag(class, name), do: [<<class ||| @named, @uncached::16>>, enc_str(name)]

  defp type_name({:sequence, type}), do: "[]" <> type_name(type)
  defp type_name({:struct, name, _types}), do: name
  defp type_name({:interface, name}), do: name
  defp type_name(type), do: Atom.to_string(type)

  ## Compressed lengths — binaryurp/source/marshal.cxx

  @doc "Encode a string with URP compressed-length prefix."
  @spec enc_str(binary()) :: binary()
  def enc_str(s), do: enc_count(byte_size(s)) <> s

  @doc "Encode a URP compressed count: one byte below 255, else 0xFF and four."
  @spec enc_count(non_neg_integer()) :: binary()
  def enc_count(count) when count < 0xFF, do: <<count>>
  def enc_count(count), do: <<0xFF, count::32>>

  @doc "Decode a compressed string, returning `{string, rest}`."
  @spec dec_str(binary()) :: {binary(), binary()}
  def dec_str(binary) do
    {length, rest} = dec_count(binary)
    <<string::binary-size(^length), rest::binary>> = rest
    {string, rest}
  end

  defp dec_count(<<0xFF, count::32, rest::binary>>), do: {count, rest}
  defp dec_count(<<count, rest::binary>>), do: {count, rest}
end
