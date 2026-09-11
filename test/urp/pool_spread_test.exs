defmodule URP.PoolSpreadTest do
  use ExUnit.Case, async: true

  alias URP.Pool

  describe "pick_address/2" do
    test "takes the first address when no worker holds one" do
      assert Pool.pick_address(["10.0.0.1", "10.0.0.2"], []) == "10.0.0.1"
    end

    test "prefers an address no worker holds" do
      assert Pool.pick_address(["10.0.0.1", "10.0.0.2"], ["10.0.0.1"]) == "10.0.0.2"
    end

    test "falls back to the least-held address once every one is taken" do
      taken = ["10.0.0.1", "10.0.0.1", "10.0.0.2"]
      assert Pool.pick_address(["10.0.0.1", "10.0.0.2"], taken) == "10.0.0.2"
    end
  end

  describe "retry_address/3" do
    test "keeps the address while the name still resolves to it" do
      assert Pool.retry_address(["10.0.0.1", "10.0.0.2"], "10.0.0.2", ["10.0.0.2"]) == "10.0.0.2"
    end

    test "picks afresh once the address has left the answer" do
      assert Pool.retry_address(["10.0.0.1", "10.0.0.3"], "10.0.0.2", ["10.0.0.1", "10.0.0.2"]) ==
               "10.0.0.3"
    end
  end

  describe "resolve/1" do
    test "returns the addresses a name resolves to, as strings" do
      assert "127.0.0.1" in Pool.resolve("localhost")
    end

    test "passes an address literal through" do
      assert Pool.resolve("127.0.0.1") == ["127.0.0.1"]
    end

    test "falls back to the name itself when resolution fails" do
      assert Pool.resolve("urp-pool.invalid") == ["urp-pool.invalid"]
    end
  end

  describe "worker bookkeeping" do
    setup do
      {:ok, pool_state} = Pool.init_pool(host: "127.0.0.1", port: 1)
      {:async, _connect, pool_state} = Pool.init_worker(pool_state)
      %{pool_state: pool_state}
    end

    test "each init_worker reserves an address in the pool state", %{pool_state: pool_state} do
      assert Keyword.fetch!(pool_state, :taken) == ["127.0.0.1"]

      {:async, _connect, pool_state} = Pool.init_worker(pool_state)
      assert Keyword.fetch!(pool_state, :taken) == ["127.0.0.1", "127.0.0.1"]
    end

    test "checkout hands the caller the bare connection", %{pool_state: pool_state} do
      conn = %URP.Bridge{}

      assert {:ok, ^conn, {"127.0.0.1", ^conn}, ^pool_state} =
               Pool.handle_checkout(
                 :checkout,
                 {self(), make_ref()},
                 {"127.0.0.1", conn},
                 pool_state
               )
    end

    test "checkin keeps the reservation next to the connection it gets back",
         %{pool_state: pool_state} do
      returned = %URP.Bridge{private: %{}}

      assert {:ok, {"127.0.0.1", ^returned}, ^pool_state} =
               Pool.handle_checkin(
                 {:ok, returned},
                 {self(), make_ref()},
                 {"127.0.0.1", %URP.Bridge{}},
                 pool_state
               )
    end

    test "terminate_worker releases the address the worker reserved", %{pool_state: pool_state} do
      {:ok, pool_state} =
        Pool.terminate_worker(:shutdown, {"127.0.0.1", %URP.Bridge{}}, pool_state)

      assert Keyword.fetch!(pool_state, :taken) == []
    end
  end
end
