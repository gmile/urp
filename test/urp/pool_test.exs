defmodule URP.PoolTest do
  use ExUnit.Case, async: true

  describe "checkout_outcome/3" do
    test "keeps the connection when a sink consumed the output" do
      assert URP.Pool.checkout_outcome(:ok, nil, false) == {:ok, :reuse}
    end

    test "wraps the output bytes when no sink consumed them" do
      assert URP.Pool.checkout_outcome("%PDF-1.7", nil, false) == {{:ok, "%PDF-1.7"}, :reuse}
    end

    test "discards the connection after stream input even on success" do
      assert URP.Pool.checkout_outcome(:ok, nil, true) == {:ok, :discard}
    end

    test "returns the result but discards the connection when cleanup failed" do
      assert URP.Pool.checkout_outcome(:ok, "close failed", false) == {:ok, :discard}
    end

    test "reports the error when the conversion produced nothing" do
      assert URP.Pool.checkout_outcome(nil, "connection closed", false) ==
               {{:error, "connection closed"}, :discard}
    end
  end
end
