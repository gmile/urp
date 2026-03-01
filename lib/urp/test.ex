defmodule URP.Test do
  @moduledoc """
  Test helpers for stubbing URP conversions without a running soffice.

  Uses `NimbleOwnership` for per-process stub isolation, so async tests work
  without global state.

  ## Setup

  No setup needed — the ownership server starts with the `:urp` application.

  ## Usage

      test "generates invoice PDF" do
        URP.Test.stub(fn _input, _opts ->
          {:ok, "%PDF-fake"}
        end)

        assert {:ok, _pdf} = MyApp.generate_invoice(order)
      end

  The stub intercepts all `URP.convert/2` calls made by the current process
  (or its children via `$callers` propagation).

  ## Stub function

  The stub receives `(input, opts)` where `input` is whatever was passed to
  `URP.convert/2` (a path, `{:binary, bytes}`, or an enumerable) and `opts`
  is the keyword list including `:output`, `:filter`, etc.

  Return the expected shape for the given `:output` mode:

    * `{:ok, path}` — default (temp file) or `output: path`
    * `{:ok, binary}` — when `output: :binary`
    * `:ok` — when `output: fun/1`
    * `{:error, message}` — for errors

  ## Process allowances

  Stubs are scoped to the process that called `stub/1`. For processes
  started with `Task` or `GenServer`, `$callers` propagation handles
  this automatically. For other processes, use `allow/2`:

      test "async worker" do
        URP.Test.stub(fn _, _ -> {:ok, "pdf"} end)
        worker = start_my_worker()
        URP.Test.allow(self(), worker)
      end
  """

  @ownership __MODULE__.Ownership

  # The key used in NimbleOwnership for global stubs
  @stub_key :urp_stub

  @doc """
  Register a stub for URP conversions in the current test process.

  ## Examples

      iex> URP.Test.stub(fn _input, _opts -> {:ok, "fake PDF"} end)
      :ok
      iex> URP.convert({:binary, "hello"}, filter: "writer_pdf_Export", output: :binary)
      {:ok, "fake PDF"}

      iex> URP.Test.stub(fn {:binary, bytes}, _opts -> {:ok, byte_size(bytes)} end)
      :ok
      iex> URP.convert({:binary, "hello"}, filter: "writer_pdf_Export", output: :binary)
      {:ok, 5}
  """
  @spec stub((term(), keyword() -> term())) :: :ok
  def stub(fun) when is_function(fun, 2) do
    {:ok, _} =
      NimbleOwnership.get_and_update(@ownership, self(), @stub_key, fn _ ->
        {:ok, fun}
      end)

    :ok
  end

  @doc """
  Allow `allowed_pid` to use the stub registered by `owner_pid`.

  Usually not needed — `$callers` propagation handles `Task` and `GenServer`
  automatically. Use this for processes that don't propagate `$callers`.
  """
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
