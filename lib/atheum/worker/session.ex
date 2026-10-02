defmodule Atheum.Worker.Session do
  @moduledoc "Bounded private Docker stdin/stdout dialogue. No socket, network or host mount."
  alias Atheum.Wire

  def open(instance, config) do
    port =
      Port.open({:spawn_executable, String.to_charlist(config.docker)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["start", "--attach", "--interactive", instance["instance_name"]]
      ])

    # A broken attach stdin is an observation failure, not a manager crash.
    Process.unlink(port)

    {:ok,
     %{
       port: port,
       buffer: "",
       received: 0,
       deadline: System.monotonic_time(:millisecond) + Map.get(config, :worker_timeout_ms, 15_000)
     }}
  rescue
    error in [ErlangError, ArgumentError] -> failure(Exception.message(error))
  end

  def send_message(session, message) do
    bytes = JSON.encode!(message) <> "\n"

    if byte_size(bytes) <= 16_384 do
      Port.command(session.port, bytes)
      :ok
    else
      failure("worker input exceeds 16384 bytes")
    end
  rescue
    ArgumentError -> failure("worker stdin unavailable")
  end

  def message(session) do
    cond do
      System.monotonic_time(:millisecond) >= session.deadline ->
        failure("worker dialogue timeout")

      byte_size(session.buffer) > 65_536 ->
        failure("worker line exceeds 65536 bytes")

      String.contains?(session.buffer, "\n") ->
        parse_message(session)

      true ->
        receive_more(session)
    end
  end

  defp parse_message(session) do
    [line, rest] = String.split(session.buffer, "\n", parts: 2)

    with {:ok, value} <- Wire.decode(line), true <- is_map(value) do
      {:ok, value, %{session | buffer: rest}}
    else
      _other -> failure("malformed worker message")
    end
  end

  defp receive_more(session) do
    receive do
      {port, {:data, bytes}} when port == session.port ->
        if session.received + byte_size(bytes) > 1_048_576 do
          failure("worker output exceeds 1048576 bytes")
        else
          message(%{
            session
            | buffer: session.buffer <> bytes,
              received: session.received + byte_size(bytes)
          })
        end

      {port, {:exit_status, status}} when port == session.port ->
        failure("worker exited before result: #{status}")
    after
      max(session.deadline - System.monotonic_time(:millisecond), 0) ->
        failure("worker dialogue timeout")
    end
  end

  def exited(session) do
    if session.buffer != "" do
      failure("unexpected worker trailing output")
    else
      receive do
        {port, {:exit_status, 0}} when port == session.port -> :ok
        {port, _other} when port == session.port -> failure("worker exit/output mismatch")
      after
        max(session.deadline - System.monotonic_time(:millisecond), 0) ->
          failure("worker exit timeout")
      end
    end
  end

  def close(session) do
    Port.close(session.port)
  rescue
    ArgumentError -> :ok
  end

  defp failure(detail), do: {:error, %{"code" => "worker_lost", "detail" => detail}}
end
