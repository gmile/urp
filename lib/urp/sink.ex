defmodule URP.Sink do
  @moduledoc false

  # Where a converted document goes as it is read back from `soffice`: memory, a
  # local file or a function called with each chunk.
  #
  # A sink that cannot take a chunk raises `URP.Error`.

  @type sink :: :binary | {:path, Path.t()} | (binary() -> any())
  @opaque t :: {:mem, iodata()} | {:file, File.io_device()} | {:fun, fun()}

  @spec open(sink()) :: t()
  def open(:binary), do: {:mem, []}
  def open(fun) when is_function(fun, 1), do: {:fun, fun}

  def open({:path, path}) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, fd} ->
        {:file, fd}

      {:error, reason} ->
        raise URP.Error, "could not open output #{path}: #{:file.format_error(reason)}"
    end
  end

  @doc "Add `chunk` to the sink."
  @spec write(t(), binary()) :: t()
  def write({:mem, chunks}, chunk), do: {:mem, [chunks, chunk]}

  def write({:file, fd} = sink, chunk) do
    case :file.write(fd, chunk) do
      :ok -> sink
      {:error, reason} -> raise URP.Error, "could not write output: #{:file.format_error(reason)}"
    end
  end

  def write({:fun, fun} = sink, chunk) do
    fun.(chunk)
    sink
  catch
    kind, reason ->
      raise URP.Error, "output sink failed: #{Exception.format_banner(kind, reason)}"
  end

  @doc "Close the sink. Returns the bytes written to memory, or `:ok`."
  @spec finish(t()) :: binary() | :ok
  def finish({:mem, chunks}), do: IO.iodata_to_binary(chunks)
  def finish({:file, fd}), do: File.close(fd)
  def finish({:fun, _fun}), do: :ok

  @doc "Let go of the sink without regard for what it holds."
  @spec release(t()) :: :ok
  def release({:file, fd}), do: with(_ <- File.close(fd), do: :ok)
  def release(_sink), do: :ok
end
