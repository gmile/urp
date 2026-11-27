defmodule URP.ProtocolTest do
  use ExUnit.Case, async: true

  alias URP.Protocol, as: P

  import Bitwise

  @reader P.reader()
  @interface "com.sun.star.io.XInputStream"

  @null <<0, 0xFFFF::16>>

  describe "decode_message/2 — request" do
    test "reads an 8-bit function id from a long header" do
      assert {{:request, 3}, @reader} = P.decode_message(<<0xC0, 3>>, @reader)
    end

    test "reads a 16-bit function id when FUNCTIONID16 is set" do
      assert {{:request, 300}, @reader} = P.decode_message(<<0xC0 ||| 0x04, 300::16>>, @reader)
    end

    test "skips the MOREFLAGS byte" do
      assert {{:request, 5}, @reader} = P.decode_message(<<0xC0 ||| 0x01, 0x80, 5>>, @reader)
    end

    test "remembers the type and object a header puts in cache slots" do
      frame =
        <<0xC0 ||| 0x01 ||| 0x20 ||| 0x10 ||| 0x08, 0x80, 3>> <>
          <<22 ||| 0x80, 5::16>> <>
          P.enc_str(@interface) <>
          P.enc_str("stream-42") <>
          <<7::16>> <>
          P.enc_str("tid-1") <>
          <<1::16>> <>
          <<1, 2, 3>>

      assert {{:request, 3}, reader} = P.decode_message(frame, @reader)
      assert reader == %{types: %{5 => @interface}, oids: %{7 => "stream-42"}}
    end

    test "leaves an uncached object out of the cache" do
      frame = <<0xC0 ||| 0x10, 3>> <> P.enc_str("once") <> <<0xFFFF::16>>

      assert {{:request, 3}, @reader} = P.decode_message(frame, @reader)
    end

    test "reads a 6-bit function id from a short header" do
      assert {{:request, 42}, @reader} = P.decode_message(<<42, 1, 2, 3>>, @reader)
    end

    test "reads a 14-bit function id when FUNCTIONID14 is set" do
      assert {{:request, 773}, @reader} = P.decode_message(<<0x40 ||| 0x03, 0x05, 1>>, @reader)
    end
  end

  describe "decode_message/2 — reply" do
    test "returns the body for decode/3 to read" do
      assert {{:reply, <<12, 3, "abc">>}, _reader} =
               P.decode_message(<<0x80, 12, 3, "abc">>, @reader)
    end

    test "steps over the thread id" do
      frame = <<0x80 ||| 0x08>> <> P.enc_str("tid-1") <> <<0xFFFF::16>> <> <<1>>

      assert {{:reply, <<1>>}, _reader} = P.decode_message(frame, @reader)
    end

    test "returns the message of an exception" do
      frame =
        <<0x80 ||| 0x20, 19 ||| 0x80, 0::16>> <>
          P.enc_str("com.sun.star.io.IOException") <> P.enc_str("file not found") <> @null

      assert {{:exception, "file not found"}, _reader} = P.decode_message(frame, @reader)
    end

    test "names the exception when it carries no message" do
      frame =
        <<0x80 ||| 0x20, 19 ||| 0x80, 0::16>> <>
          P.enc_str("com.sun.star.io.IOException") <> P.enc_str("") <> @null

      assert {{:exception, "com.sun.star.io.IOException"}, reader} =
               P.decode_message(frame, @reader)

      assert {{:exception, "com.sun.star.io.IOException"}, _reader} =
               P.decode_message(<<0x80 ||| 0x20, 19, 0::16, 0>> <> @null, reader)
    end

    test "remembers the object an exception names as its context" do
      frame =
        <<0x80 ||| 0x20, 19, 0::16>> <> P.enc_str("denied") <> P.enc_str("object-9") <> <<3::16>>

      assert {{:exception, "denied"}, %{oids: %{3 => "object-9"}}} =
               P.decode_message(frame, @reader)
    end
  end

  describe "decode/3" do
    test "reads a string out of an any" do
      assert {"25.8.1.1", <<>>, _reader} =
               P.decode(:any, <<12>> <> P.enc_str("25.8.1.1"), @reader)
    end

    test "reads a void any as nil" do
      assert {nil, <<>>, _reader} = P.decode(:any, <<0>>, @reader)
    end

    test "reads an object reference out of an any, learning its type" do
      binary =
        <<22 ||| 0x80, 4::16>> <> P.enc_str(@interface) <> P.enc_str("object-1") <> <<0xFFFF::16>>

      assert {"object-1", <<>>, %{types: %{4 => @interface}}} = P.decode(:any, binary, @reader)
    end

    test "remembers an object reference and resolves it from its cache slot" do
      {oid, <<>>, reader} =
        P.decode({:interface, nil}, P.enc_str("document-1") <> <<7::16>>, @reader)

      assert oid == "document-1"
      assert {"document-1", <<>>, _reader} = P.decode({:interface, nil}, <<0, 7::16>>, reader)
    end

    test "reads a null object reference as nil" do
      assert {nil, <<>>, _reader} = P.decode({:interface, nil}, <<0, 0xFFFF::16>>, @reader)
    end

    test "reads a sequence of strings" do
      binary = <<2>> <> P.enc_str("foo") <> P.enc_str("bar")

      assert {["foo", "bar"], <<>>, _reader} = P.decode({:sequence, :string}, binary, @reader)
      assert {[], <<>>, _reader} = P.decode({:sequence, :string}, <<0>>, @reader)
    end

    test "reads a sequence whose count takes the extended form" do
      binary = <<0xFF, 2::32>> <> P.enc_str("a") <> P.enc_str("b")

      assert {["a", "b"], <<>>, _reader} = P.decode({:sequence, :string}, binary, @reader)
    end

    test "leaves what follows the value" do
      assert {7, <<9>>, _reader} = P.decode(:long, <<7::32, 9>>, @reader)
    end
  end

  describe "encode/2" do
    test "writes an any as its type and then its value" do
      assert IO.iodata_to_binary(P.encode(:any, {:string, "x"})) == <<12, 1, "x">>
      assert IO.iodata_to_binary(P.encode(:any, {:long, -1})) == <<6, 255, 255, 255, 255>>
      assert IO.iodata_to_binary(P.encode(:any, {:void, nil})) == <<0>>
    end

    test "names a sequence type after its element" do
      property = {:struct, "com.sun.star.beans.PropertyValue", [:string, :long, :any, :long]}
      encoded = IO.iodata_to_binary(P.encode(:any, {{:sequence, property}, []}))

      assert encoded ==
               <<20 ||| 0x80, 0xFFFF::16>> <>
                 P.enc_str("[]com.sun.star.beans.PropertyValue") <> <<0>>
    end

    test "writes a struct as its members in order" do
      struct = {:struct, "com.sun.star.beans.NamedValue", [:string, :any]}

      assert IO.iodata_to_binary(P.encode(struct, ["nodepath", {:boolean, true}])) ==
               P.enc_str("nodepath") <> <<2, 1>>
    end

    test "writes an object reference uncached, and null as an empty one" do
      assert IO.iodata_to_binary(P.encode({:interface, @interface}, "object-1")) ==
               P.enc_str("object-1") <> <<0xFFFF::16>>

      assert IO.iodata_to_binary(P.encode({:interface, @interface}, nil)) == <<0, 0xFFFF::16>>
    end

    test "round-trips through decode/3" do
      for {type, value} <- [
            boolean: true,
            long: -5,
            hyper: 1 <<< 40,
            string: "héllo",
            bytes: <<0, 255>>
          ] do
        encoded = IO.iodata_to_binary(P.encode(type, value))
        assert {^value, <<>>, _reader} = P.decode(type, encoded, @reader)
      end
    end
  end

  describe "request/5" do
    test "spells out the type, object and thread, caching none of them" do
      frame = IO.iodata_to_binary(P.request(3, @interface, "object-1", "tid-1", long: 7))

      assert {{:request, 3}, @reader} = P.decode_message(frame, @reader)
      assert String.ends_with?(frame, P.enc_str("tid-1") <> <<0xFFFF::16>> <> @null <> <<7::32>>)
    end
  end

  describe "enc_str/1 and dec_str/1" do
    test "round-trips a short string" do
      assert P.dec_str(P.enc_str("hello")) == {"hello", <<>>}
      assert P.dec_str(P.enc_str("")) == {"", <<>>}
    end

    test "uses a one-byte length through 254 bytes and five bytes from 255" do
      assert <<254, _::binary-size(254)>> = P.enc_str(String.duplicate("x", 254))
      assert <<0xFF, 255::32, _::binary-size(255)>> = P.enc_str(String.duplicate("x", 255))
    end

    test "decodes with trailing data" do
      assert P.dec_str(P.enc_str("hello") <> "extra") == {"hello", "extra"}
    end
  end

  describe "enc_count/1" do
    test "uses the compact form through 254 and the extended form from 255" do
      assert P.enc_count(254) == <<254>>
      assert P.enc_count(255) == <<0xFF, 255::32>>
    end
  end
end
