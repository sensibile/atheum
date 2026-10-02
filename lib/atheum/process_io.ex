defmodule Atheum.ProcessIO do
  @moduledoc "Bounded local process observation. Closing a Port never proves effect absence."
  @max_output 1_048_576
  @max_timeout 60_000

  def run(binary, args, timeout, env \\ [])

  def run(binary, args, timeout, env)
      when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout do
    port =
      Port.open({:spawn_executable, String.to_charlist(binary)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: args,
        env:
          Enum.map(env, fn {key, value} ->
            {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
          end)
      ])

    collect(port, [], 0, System.monotonic_time(:millisecond) + timeout)
  rescue
    error in [ErlangError, ArgumentError] ->
      failure("transport_failure", Exception.message(error))
  end

  def run(_binary, _args, _timeout, _env),
    do: failure("invalid_configuration", "timeout must be 1..60000ms")

  defp collect(port, chunks, size, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close(port, "timeout", "observation deadline exceeded; process/effect unknown")
    else
      receive do
        {^port, {:data, bytes}} ->
          if size + byte_size(bytes) > @max_output do
            close(port, "output_limit", "process output exceeds 1048576 bytes; effect unknown")
          else
            collect(port, [bytes | chunks], size + byte_size(bytes), deadline)
          end

        {^port, {:exit_status, status}} ->
          {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
      after
        remaining ->
          close(port, "timeout", "observation deadline exceeded; process/effect unknown")
      end
    end
  end

  defp close(port, code, detail) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    failure(code, detail)
  end

  defp failure(code, detail), do: {:error, %{"code" => code, "detail" => detail}}
end
