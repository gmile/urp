defmodule URP.Test do
  @moduledoc """
  Test helpers for stubbing URP conversions without a running soffice.

  Uses `NimbleOwnership` for per-process stub isolation, so async tests work
  without global state and without modifying production code.

  ## Setup

      # test/test_helper.exs
      URP.Test.start()
      ExUnit.start()

  ## Usage

  Define a wrapper module with `use URP`:

      defmodule MyApp.Converter do
        use URP, host: "soffice", port: 2002
      end

  In tests, stub it:

      test "generates invoice PDF" do
        URP.Test.stub(MyApp.Converter, fn _input, _opts ->
          {:ok, "%PDF-fake"}
        end)

        # MyApp.Converter.convert_stream/2 returns the stub
        assert {:ok, _pdf} = MyApp.generate_invoice(order)
      end

  The stub intercepts calls on wrapper modules defined with `use URP`.
  Core modules (`URP`, `URP.Connection`, `URP.Pool`) are never modified.

  ## Stub function

  The stub receives `(input, opts)` and must return the expected shape:

    * `{:ok, binary}` — for in-memory results
    * `:ok` — when a `:sink` is provided
    * `{:error, message}` — for errors

  ## Process allowances

  Stubs are scoped to the process that called `stub/2`. For processes
  started with `Task` or `GenServer`, `$callers` propagation handles
  this automatically. For other processes, use `allow/3`:

      test "async worker" do
        URP.Test.stub(MyApp.Converter, fn _, _ -> {:ok, "pdf"} end)
        worker = start_my_worker()
        URP.Test.allow(MyApp.Converter, self(), worker)
      end
  """

  @ownership __MODULE__.Ownership

  @doc """
  Start the test ownership server.

  Call this in `test/test_helper.exs` before `ExUnit.start()`.
  """
  @spec start() :: {:ok, pid()} | {:error, term()}
  def start do
    NimbleOwnership.start_link(name: @ownership)
  end

  @doc """
  Register a stub for the given module in the current test process.

  ## Examples

      URP.Test.stub(MyApp.Converter, fn _input, _opts -> {:ok, "fake PDF"} end)

      URP.Test.stub(MyApp.Converter, fn input, opts ->
        assert byte_size(input) > 0
        if opts[:sink], do: :ok, else: {:ok, "converted"}
      end)
  """
  @spec stub(module(), (binary() | Path.t(), keyword() -> term())) :: :ok
  def stub(module, fun) when is_atom(module) and is_function(fun, 2) do
    {:ok, _} =
      NimbleOwnership.get_and_update(@ownership, self(), module, fn _ ->
        {:ok, fun}
      end)

    :ok
  end

  @doc """
  Allow `allowed_pid` to use the stub registered by `owner_pid` for `module`.

  Usually not needed — `$callers` propagation handles `Task` and `GenServer`
  automatically. Use this for processes that don't propagate `$callers`.
  """
  @spec allow(module(), pid(), pid() | (-> pid() | [pid()])) :: :ok
  def allow(module, owner_pid \\ self(), allowed_pid) when is_atom(module) do
    :ok = NimbleOwnership.allow(@ownership, owner_pid, allowed_pid, module)
  end

  @doc false
  @spec __fetch_stub__(module()) :: {:ok, function()} | :error
  def __fetch_stub__(module) do
    with pid when is_pid(pid) <- GenServer.whereis(@ownership),
         callers = [self() | Process.get(:"$callers", [])],
         {:ok, owner} <- NimbleOwnership.fetch_owner(pid, callers, module),
         %{^module => fun} when is_function(fun, 2) <- NimbleOwnership.get_owned(pid, owner) do
      {:ok, fun}
    else
      _ -> :error
    end
  end
end
