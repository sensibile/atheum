defmodule Atheum.Core do
  alias Atheum.Wire
  @u64_max 18_446_744_073_709_551_615
  @moduledoc "Pure single-Function input and recovery decisions."
  def validate(%{"supplier_id" => id, "active" => active, "expected_version" => version} = input)
      when is_binary(id) and is_boolean(active) do
    if valid_id?(id) and u64?(version) and
         Enum.sort(Map.keys(input)) == ["active", "expected_version", "supplier_id"],
       do: :ok,
       else: {:error, :invalid_input}
  end

  def validate(_input), do: {:error, :invalid_input}

  defp valid_id?(id), do: byte_size(id) in 1..128 and String.valid?(id) and String.trim(id) != ""
  defp u64?(version), do: is_integer(version) and version >= 0 and version <= @u64_max

  def recoverable(row, now_ms, target) do
    request = row["request"]

    cond do
      row["status"] not in ["running", "unresolved"] -> {:error, :not_recoverable}
      row["cancel_requested"] -> {:error, :cancel_requested}
      now_ms >= request["deadline_ms"] -> {:error, :deadline_expired}
      request["target"] != target -> {:error, :target_changed}
      row["error"] && row["error"]["code"] == "request_conflict" -> {:error, :request_conflict}
      not request["safe_retry"] -> {:error, :retry_disabled}
      true -> :ok
    end
  end

  def completion({:ok, result}) do
    if Wire.valid_result?(result) do
      certainty = if result["changed"], do: "confirmed_present", else: "confirmed_absent"
      {"succeeded", certainty, result, nil}
    else
      completion(
        {:error, %{"code" => "transport_failure", "detail" => "invalid Function result"}}
      )
    end
  end

  def completion({:error, %{"code" => code} = error})
      when code in ["version_conflict", "invalid_input"] do
    {"failed", "confirmed_absent", nil, error}
  end

  def completion({:error, error}), do: {"unresolved", "unknown", nil, error}
end
