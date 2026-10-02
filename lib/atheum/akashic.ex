defmodule Atheum.Akashic do
  @moduledoc "Existing Akashic CLI only; bounded observation never proves effect absence."
  alias Atheum.{ProcessIO, Wire}

  def apply(request, config) do
    flag = if config.storage == :records, do: "--records-db", else: "--db"
    args = [flag, config.akashic_db, "--json", JSON.encode!(request)]

    with {:ok, output, status} <- ProcessIO.run(config.binary, args, config.timeout_ms),
         {:ok, wire} <- Wire.decode(output) do
      Wire.response(wire, status, request)
    end
  end
end
