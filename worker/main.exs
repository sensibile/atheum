defmodule Atheum.Worker.Main do
  @moduledoc "One stdin job, one host effect observation, one final result, then exit."
  alias Atheum.Worker.Protocol

  def run([instance, generation]) do
    emit(Protocol.ready(instance, String.to_integer(generation)))

    with {:ok, job} <- read_line(),
         true <- job["instance"] == instance,
         {:ok, effect} <- Protocol.plan(job),
         :ok <- emit(effect),
         {:ok, observation} <- read_line(),
         {:ok, result} <- Protocol.result(job, observation) do
      emit(result)
    else
      _other -> System.halt(2)
    end
  end

  defp read_line, do: read_line([], 0)
  defp read_line(_bytes, 16_384), do: {:error, :input_limit}

  defp read_line(bytes, count) do
    case IO.binread(:stdio, 1) do
      "\n" -> bytes |> Enum.reverse() |> IO.iodata_to_binary() |> Atheum.Wire.decode()
      :eof -> {:error, :eof}
      byte when is_binary(byte) -> read_line([byte | bytes], count + 1)
      _other -> {:error, :input_failure}
    end
  end

  defp emit(value), do: IO.puts(JSON.encode!(value))
end

Atheum.Worker.Main.run(System.argv())
