defmodule URP.Test do
  @moduledoc """
  Stub `URP.convert/2` in tests, without a running soffice.

      test "generates invoice PDF" do
        URP.Test.stub(fn _input, _opts -> {:ok, "%PDF-fake"} end)

        assert {:ok, _pdf} = MyApp.generate_invoice(order)
      end

  The stub is called with the input and options `convert/2` was given, after
  the options have been checked, and what it returns is what `convert/2`
  returns: `{:ok, path}`, `{:ok, bytes}` or `:ok` to match the `:output` asked
  for, or `{:error, reason}`.

  A stub belongs to the process that set it, so async tests are safe. Tasks
  started by that process use it too; a process started some other way has to
  be given it with `allow/2`.
  """

  @ownership __MODULE__.Ownership

  @stub_key :urp_stub

  @doc """
  Answer `URP.convert/2` with `fun` for the current process.

      iex> URP.Test.stub(fn {:binary, bytes}, _opts -> {:ok, String.upcase(bytes)} end)
      :ok
      iex> URP.convert({:binary, "hello"}, filter: "writer_pdf_Export", output: :binary)
      {:ok, "HELLO"}
  """
  @spec stub((term(), keyword() -> term())) :: :ok
  def stub(fun) when is_function(fun, 2) do
    {:ok, _} =
      NimbleOwnership.get_and_update(@ownership, self(), @stub_key, fn _ ->
        {:ok, fun}
      end)

    :ok
  end

  @doc "Let `allowed_pid` use the stub set by `owner_pid`."
  @spec allow(pid(), pid() | (-> pid() | [pid()])) :: :ok
  def allow(owner_pid \\ self(), allowed_pid) do
    :ok = NimbleOwnership.allow(@ownership, owner_pid, allowed_pid, @stub_key)
  end

  @doc false
  @spec __fetch_stub__() :: {:ok, function()} | :error
  def __fetch_stub__ do
    with pid when is_pid(pid) <- GenServer.whereis(@ownership),
         callers = [self() | Process.get(:"$callers", [])],
         {:ok, owner} <- NimbleOwnership.fetch_owner(pid, callers, @stub_key),
         %{@stub_key => fun} when is_function(fun, 2) <- NimbleOwnership.get_owned(pid, owner) do
      {:ok, fun}
    else
      _ -> :error
    end
  end
end
