# Req-style API Refactor — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace `use URP` macro with Req-style architecture where the library manages its own pools and test infrastructure.

**Architecture:** `URP.Application` starts a default pool, DynamicSupervisor for named pools, and NimbleOwnership for test stubs. `URP` module becomes the sole public API — all calls go through pools, stubs intercept before pool dispatch.

**Tech Stack:** Elixir 1.19, NimblePool, NimbleOwnership, ExUnit

**Run tests with:** `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix test"`

---

### Task 1: Add URP.Application — start the supervision tree

This is the foundation. The app needs to start before anything works.

**Files:**
- Create: `lib/urp/application.ex`
- Modify: `mix.exs:50-52` (add `mod:` to `application/0`)

**Step 1: Create `lib/urp/application.ex`**

```elixir
defmodule URP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {NimblePool,
       worker: {URP.Pool, default_pool_config()},
       pool_size: default_pool_size(),
       name: URP.Pool.Default},
      {DynamicSupervisor, strategy: :one_for_one, name: URP.PoolSupervisor},
      {NimbleOwnership, name: URP.Test.Ownership}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: URP.Supervisor)
  end

  defp default_pool_config do
    config = Application.get_env(:urp, :default, [])

    %{
      host: Keyword.get(config, :host, "localhost"),
      port: Keyword.get(config, :port, 2002)
    }
  end

  defp default_pool_size do
    config = Application.get_env(:urp, :default, [])
    Keyword.get(config, :pool_size, 1)
  end
end
```

**Step 2: Add `mod:` to `mix.exs`**

Change `application/0` from:

```elixir
def application do
  [extra_applications: [:crypto]]
end
```

To:

```elixir
def application do
  [
    extra_applications: [:crypto],
    mod: {URP.Application, []}
  ]
end
```

**Step 3: Make `nimble_ownership` a required dependency**

In `mix.exs`, change:

```elixir
{:nimble_ownership, "~> 1.0", optional: true}
```

To:

```elixir
{:nimble_ownership, "~> 1.0"}
```

It starts unconditionally now (like Req), so it can't be optional.

**Step 4: Run tests**

Run: `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix test"`

Expected: All 48 tests pass. The new Application starts alongside the existing code. Nothing uses it yet.

**Step 5: Commit**

```bash
git add lib/urp/application.ex mix.exs
git commit -m "Add URP.Application with default pool, DynamicSupervisor, and ownership server"
```

---

### Task 2: Simplify URP.Pool — remove otp_app and default name logic

`URP.Pool` currently handles its own config resolution (`otp_app`, `name` defaulting). With `URP.Application` managing pool startup, `URP.Pool` can be simplified to just accept explicit opts. The NimblePool callbacks stay exactly the same.

**Files:**
- Modify: `lib/urp/pool.ex:39-80` (simplify `start_link` and `child_spec`)

**Step 1: Simplify `start_link/1`**

Replace the current `start_link/1` (lines 53-72) with:

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
def start_link(opts \\ []) do
  {name, opts} = Keyword.pop!(opts, :name)
  {pool_size, opts} = Keyword.pop(opts, :pool_size, 1)

  NimblePool.start_link(
    worker: {__MODULE__, Map.new(opts)},
    pool_size: pool_size,
    name: name
  )
end
```

**Step 2: Simplify `child_spec/1`**

Replace (lines 74-80) with:

```elixir
@doc false
def child_spec(opts) do
  %{
    id: Keyword.fetch!(opts, :name),
    start: {__MODULE__, :start_link, [opts]}
  }
end
```

**Step 3: Update moduledoc**

Replace the Setup section in the moduledoc to reflect that pools are managed by `URP.Application`, not directly by users.

**Step 4: Run tests**

Run: `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix test"`

Expected: Tests that start pools directly (e.g. `start_supervised!({URP.Pool, name: :test_pool, pool_size: 2})`) still pass because they provide `:name`.

**Step 5: Commit**

```bash
git add lib/urp/pool.ex
git commit -m "Simplify URP.Pool: remove otp_app config resolution, require explicit name"
```

---

### Task 3: Rewrite URP module — pool dispatch with stub check

Replace the `__using__` macro, direct-connection functions, and helpers with the new pool-based API. This is the core change.

**Files:**
- Rewrite: `lib/urp.ex`

**Step 1: Write the new `lib/urp.ex`**

```elixir
defmodule URP do
  @moduledoc """
  Pure Elixir client for document conversion via LibreOffice's UNO Remote Protocol.

  Talks directly to a `soffice` process over TCP.
  No Python, no unoserver, no Gotenberg.

  ## Setup

  Add `:urp` to your dependencies — that's it. A default connection pool
  starts automatically, connecting to `localhost:2002`.

      # config/runtime.exs (optional — defaults shown)
      config :urp, :default,
        host: "soffice",
        port: 2002,
        pool_size: 1

  ## Usage

      {:ok, pdf_bytes} = URP.convert_stream(docx_bytes)
      {:ok, pdf_bytes} = URP.convert_file_stream("/path/to/input.docx")
      :ok = URP.convert_stream(docx_bytes, sink: {:path, "/tmp/out.pdf"})

  ## Named pools

  For multiple soffice instances, configure named pools:

      config :urp, :pools,
        spreadsheets: [host: "soffice-2", port: 2002, pool_size: 3]

      {:ok, pdf} = URP.convert_stream(bytes, pool: :spreadsheets)

  Named pools are started on first use.

  ## Testing

      URP.Test.stub(fn _input, _opts -> {:ok, "fake pdf"} end)
      {:ok, "fake pdf"} = URP.convert_stream(docx_bytes)

  See `URP.Test` for details.
  """

  @type sink :: {:path, Path.t()} | (binary() -> any())
  @type opt ::
          {:pool, atom()}
          | {:filter, String.t()}
          | {:sink, sink()}
          | {:timeout, non_neg_integer()}

  @doc """
  Convert document bytes to PDF via streaming.

  ## Options

    * `:pool`    — named pool to use (default: `URP.Pool.Default`)
    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:sink`    — output destination: `{:path, path}` or `fun/1` (default: in-memory)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec convert_stream(binary(), [opt()]) :: {:ok, binary()} | :ok | {:error, String.t()}
  def convert_stream(input_bytes, opts \\ []) when is_binary(input_bytes) do
    case URP.Test.__fetch_stub__() do
      {:ok, fun} -> fun.(input_bytes, opts)
      :error ->
        {pool, opts} = resolve_pool(opts)
        URP.Pool.convert_stream(pool, input_bytes, opts)
    end
  end

  @doc """
  Convert a local file to PDF via file-backed streaming.

  Accepts the same options as `convert_stream/2`.
  """
  @spec convert_file_stream(Path.t(), [opt()]) :: {:ok, binary()} | :ok | {:error, String.t()}
  def convert_file_stream(input_path, opts \\ []) when is_binary(input_path) do
    case URP.Test.__fetch_stub__() do
      {:ok, fun} -> fun.(input_path, opts)
      :error ->
        {pool, opts} = resolve_pool(opts)
        URP.Pool.convert_file_stream(pool, input_path, opts)
    end
  end

  @doc """
  Convert a file to PDF via file:// URLs (requires shared filesystem).

  ## Options

    * `:pool`    — named pool to use (default: `URP.Pool.Default`)
    * `:filter`  — export filter name (default `"writer_pdf_Export"`)
    * `:timeout` — checkout timeout in ms (default `120_000`)
  """
  @spec convert(Path.t(), Path.t() | nil, [opt()]) ::
          {:ok, Path.t()} | {:error, String.t()}
  def convert(input_path, output_path \\ nil, opts \\ []) do
    case URP.Test.__fetch_stub__() do
      {:ok, fun} -> fun.(input_path, opts)
      :error ->
        {pool, opts} = resolve_pool(opts)
        URP.Pool.convert(pool, input_path, output_path, opts)
    end
  end

  defp resolve_pool(opts) do
    {pool_name, opts} = Keyword.pop(opts, :pool)

    pool =
      if pool_name do
        ensure_pool!(pool_name)
      else
        URP.Pool.Default
      end

    {pool, opts}
  end

  @doc false
  def ensure_pool!(name) do
    pid_name = pool_process_name(name)

    case GenServer.whereis(pid_name) do
      pid when is_pid(pid) ->
        pid_name

      nil ->
        pools = Application.get_env(:urp, :pools, [])

        case Keyword.fetch(pools, name) do
          {:ok, config} ->
            opts = [
              name: pid_name,
              host: Keyword.get(config, :host, "localhost"),
              port: Keyword.get(config, :port, 2002),
              pool_size: Keyword.get(config, :pool_size, 1)
            ]

            case DynamicSupervisor.start_child(URP.PoolSupervisor, {URP.Pool, opts}) do
              {:ok, _pid} -> pid_name
              {:error, {:already_started, _pid}} -> pid_name
            end

          :error ->
            raise ArgumentError,
                  "pool #{inspect(name)} is not configured. " <>
                    "Add it to config :urp, :pools, #{name}: [host: \"...\", port: 2002]"
        end
    end
  end

  defp pool_process_name(name), do: :"URP.Pool.#{name}"
end
```

**Step 2: Run tests**

Run: `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix test"`

Expected: Most integration tests pass (they call `URP.convert_stream` etc. which now goes through the default pool). Some tests will fail because:
- `URPTest.StubConverter` still uses `use URP` (will fix in Task 5)
- Direct pool tests call `URP.Pool.convert_stream(:test_pool, ...)` — these still work

**Step 3: Commit**

```bash
git add lib/urp.ex
git commit -m "Rewrite URP module: pool dispatch with stub check, remove macro and direct-connection path"
```

---

### Task 4: Rewrite URP.Test — global stubs instead of per-module

Stubs are no longer per-module (no modules to stub against). Instead, `stub/1` registers a global stub for the calling process.

**Files:**
- Rewrite: `lib/urp/test.ex`

**Step 1: Write the new `lib/urp/test.ex`**

```elixir
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

  The stub intercepts all `URP.convert_stream/2`, `URP.convert_file_stream/2`,
  and `URP.convert/3` calls made by the current process (or its children via
  `$callers` propagation).

  ## Stub function

  The stub receives `(input, opts)` and must return the expected shape:

    * `{:ok, binary}` — for in-memory results
    * `:ok` — when a `:sink` is provided
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

      URP.Test.stub(fn _input, _opts -> {:ok, "fake PDF"} end)

      URP.Test.stub(fn input, opts ->
        assert byte_size(input) > 0
        if opts[:sink], do: :ok, else: {:ok, "converted"}
      end)
  """
  @spec stub((binary() | Path.t(), keyword() -> term())) :: :ok
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
```

**Step 2: Run tests**

Run: `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix test"`

Expected: Compilation may warn about old `URP.Test.stub/2` calls in tests. Test failures expected — we fix them in the next task.

**Step 3: Commit**

```bash
git add lib/urp/test.ex
git commit -m "Rewrite URP.Test: global stubs instead of per-module, remove start/0"
```

---

### Task 5: Rewrite tests to use new API

Update all tests to use the new `URP.convert_stream(bytes)` API and `URP.Test.stub(fn ...)` without module names.

**Files:**
- Rewrite: `test/urp_test.exs`
- Modify: `test/test_helper.exs`

**Step 1: Simplify `test/test_helper.exs`**

Replace entire file with:

```elixir
case :gen_tcp.connect(~c"localhost", 2002, [:binary], 1000) do
  {:ok, sock} ->
    :gen_tcp.close(sock)

  {:error, _} ->
    raise "soffice not reachable on localhost:2002 — start it before running tests"
end

ExUnit.start()
```

`URP.Test.start()` is gone — the ownership server starts with the application.

**Step 2: Rewrite `test/urp_test.exs`**

Remove `URPTest.StubConverter` module entirely. Update all tests:

- `URP.convert(...)` calls stay the same (API unchanged, just goes through pool now)
- `URP.convert_stream(...)` calls stay the same
- `URP.convert_file_stream(...)` calls stay the same
- `URP.Pool` describe block: tests call `URP.convert_stream(bytes)` via the default pool started by the app (no need to `start_supervised!` a pool)
- `URP.Test` describe block: use `URP.Test.stub(fn ...)` without module name, assert via `URP.convert_stream(...)`

The pool tests that tested multiple pools / pool names can test named pools via config:

```elixir
describe "URP.Pool" do
  test "converts via default pool" do
    docx_bytes = build_test_docx()
    assert {:ok, pdf} = URP.convert_stream(docx_bytes)
    assert <<"%PDF-" <> _rest>> = pdf
  end

  test "handles consecutive streaming conversions" do
    docx_bytes = build_test_docx()
    assert {:ok, pdf1} = URP.convert_stream(docx_bytes)
    assert {:ok, pdf2} = URP.convert_stream(docx_bytes)
    assert <<"%PDF-" <> _rest>> = pdf1
    assert <<"%PDF-" <> _rest>> = pdf2
  end
end
```

The error handling tests that used `start_supervised!({URP.Pool, name: :error_pool})` should use the default pool directly:

```elixir
describe "error handling" do
  test "returns error for nonexistent file via pool" do
    id = System.unique_integer([:positive])
    assert {:error, _message} =
             URP.convert_file_stream("/tmp/nonexistent_#{id}.docx")
  end

  test "pool stays alive after error" do
    id = System.unique_integer([:positive])
    assert {:error, _} = URP.convert_file_stream("/tmp/nonexistent_#{id}.docx")
    # Default pool should still be alive
    assert {:ok, pdf} = URP.convert_stream(build_test_docx())
    assert <<"%PDF-" <> _rest>> = pdf
  end
end
```

The stub tests:

```elixir
describe "URP.Test" do
  test "stub bypasses real conversion" do
    URP.Test.stub(fn input, _opts ->
      assert input == "hello"
      {:ok, "fake PDF"}
    end)

    assert {:ok, "fake PDF"} = URP.convert_stream("hello")
  end

  test "stub works with convert_file_stream" do
    URP.Test.stub(fn input, _opts ->
      assert input == "/tmp/test.docx"
      {:ok, "fake PDF"}
    end)

    assert {:ok, "fake PDF"} = URP.convert_file_stream("/tmp/test.docx")
  end

  test "stub receives opts" do
    URP.Test.stub(fn _input, opts ->
      assert opts[:filter] == "calc_pdf_Export"
      {:ok, "filtered"}
    end)

    assert {:ok, "filtered"} =
             URP.convert_stream("bytes", filter: "calc_pdf_Export")
  end

  test "stub is per-process via $callers" do
    URP.Test.stub(fn _input, _opts -> {:ok, "parent stub"} end)

    task =
      Task.async(fn ->
        URP.convert_stream("bytes")
      end)

    assert {:ok, "parent stub"} = Task.await(task)
  end
end
```

**Step 3: Run tests**

Run: `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix test"`

Expected: All tests pass.

**Step 4: Commit**

```bash
git add test/urp_test.exs test/test_helper.exs
git commit -m "Rewrite tests for new Req-style API"
```

---

### Task 6: Update README and docs

Update README to reflect the new API. Remove `use URP` setup instructions, add config-driven setup.

**Files:**
- Modify: `README.md`

**Step 1: Update README**

Key changes:
- **Installation**: Remove `nimble_ownership` from user deps (it's a regular dep now)
- **Setup**: Replace `use URP` / supervision tree with just config
- **Usage**: `URP.convert_stream(bytes)` instead of `MyApp.Converter.convert_stream(bytes)`
- **Named pools**: New section
- **Testing**: `URP.Test.stub(fn ...)` without module name, no `URP.Test.start()`
- **Architecture table**: Update module roles

**Step 2: Run tests** (sanity check)

Run: `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix test"`

Expected: All tests pass.

**Step 3: Commit**

```bash
git add README.md
git commit -m "Update README for Req-style API"
```

---

### Task 7: Clean up — remove unused code, verify CI

Final cleanup pass.

**Files:**
- Verify: `lib/urp/pool.ex` — remove default `pool \\ __MODULE__` from public functions since pool is always passed explicitly now
- Verify: no references to old `use URP` pattern remain
- Verify: dialyzer passes

**Step 1: Remove default pool arguments from URP.Pool public functions**

In `lib/urp/pool.ex`, change:

```elixir
def convert_stream(pool \\ __MODULE__, input_bytes, opts \\ [])
```

To:

```elixir
def convert_stream(pool, input_bytes, opts \\ [])
```

Same for `convert_file_stream` and `convert`. These are now internal — always called with an explicit pool name.

**Step 2: Run full verification**

Run: `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix test && mix compile --warnings-as-errors && mix format --check-formatted"`

Expected: All pass.

**Step 3: Run dialyzer**

Run: `nix-shell -p beam.packages.erlang_28.elixir_1_19 --run "mix dialyzer"`

Expected: No new warnings. May need to update specs if dialyzer complains about changed arities.

**Step 4: Commit**

```bash
git add lib/urp/pool.ex
git commit -m "Remove default pool arguments from URP.Pool — always called with explicit pool name"
```
