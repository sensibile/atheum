defmodule Atheum.Wire do
  @moduledoc "Pure bounded JSON and Akashic response contract validation."
  @u64_max 18_446_744_073_709_551_615

  def decode(bytes) do
    decoders = [
      object_start: fn _acc -> %{} end,
      object_push: &object_push/3,
      object_finish: fn object, acc -> {object, acc} end
    ]

    with :ok <- depth(bytes, 0, false, false),
         {value, _acc, rest} <- JSON.decode(bytes, nil, decoders),
         true <- String.trim(rest) == "" do
      {:ok, value}
    else
      _other -> failure()
    end
  catch
    :duplicate_json_key -> failure()
  end

  defp object_push(key, value, object) do
    if Map.has_key?(object, key),
      do: throw(:duplicate_json_key),
      else: Map.put(object, key, value)
  end

  defp depth(<<>>, 0, false, false), do: :ok
  defp depth(<<>>, _level, _string, _escape), do: :error
  defp depth(<<_char, rest::binary>>, level, true, true), do: depth(rest, level, true, false)
  defp depth(<<92, rest::binary>>, level, true, false), do: depth(rest, level, true, true)
  defp depth(<<34, rest::binary>>, level, true, false), do: depth(rest, level, false, false)
  defp depth(<<_char, rest::binary>>, level, true, false), do: depth(rest, level, true, false)
  defp depth(<<34, rest::binary>>, level, false, false), do: depth(rest, level, true, false)
  defp depth(<<char, _rest::binary>>, 32, false, false) when char in [91, 123], do: :error

  defp depth(<<char, rest::binary>>, level, false, false) when char in [91, 123],
    do: depth(rest, level + 1, false, false)

  defp depth(<<char, rest::binary>>, level, false, false) when char in [93, 125] and level > 0,
    do: depth(rest, level - 1, false, false)

  defp depth(<<char, _rest::binary>>, 0, false, false) when char in [93, 125], do: :error
  defp depth(<<_char, rest::binary>>, level, false, false), do: depth(rest, level, false, false)

  def response(wire, status, request) when is_map(wire) and is_integer(status) do
    case {Enum.sort(Map.keys(wire)), wire["ok"], status} do
      {["ok", "result"], true, 0} -> success(wire["result"], request)
      {["error", "ok"], false, 2} -> rejection(wire["error"])
      _other -> failure()
    end
  end

  def response(_wire, _status, _request), do: failure()

  defp success(%{"apply" => result} = payload, %{"command" => "apply", "request" => request}) do
    if apply_payload?(payload) and apply_result?(result, request["expected_version"]),
      do: {:ok, result},
      else: failure()
  end

  defp success(result, %{"command" => "impact", "version" => version}) do
    if exact_keys?(result, ["blocked_by_product", "version", "work"]) and
         u64?(version) and result["version"] == version and
         blocked?(result["blocked_by_product"]) and work?(result["work"]),
       do: {:ok, result},
       else: failure()
  end

  defp success(%{"valid" => true, "version" => version} = result, %{"command" => "validate"}) do
    if exact_keys?(result, ["valid", "version"]) and u64?(version),
      do: {:ok, result},
      else: failure()
  end

  defp success(_result, _request), do: failure()

  defp rejection(%{"code" => code, "detail" => detail} = error)
       when is_binary(code) and is_binary(detail) do
    if exact_keys?(error, ["code", "detail"]) and String.valid?(code) and
         String.trim(code) != "" and String.valid?(detail), do: {:error, error}, else: failure()
  end

  defp rejection(_error), do: failure()

  defp apply_payload?(payload) do
    # Current CLI may include these separate I/O measurements; they are not effect evidence.
    payload
    |> Map.drop(["apply"])
    |> Enum.all?(fn {key, value} -> key in ["open_work", "write_work"] and is_map(value) end)
  end

  defp exact_keys?(value, keys) when is_map(value), do: Enum.sort(Map.keys(value)) == keys
  defp exact_keys?(_value, _keys), do: false

  def apply_result?(result, expected) when is_map(result) and is_integer(expected) do
    changed = result["changed"]
    version = result["version"]

    exact_keys?(result, ["changed", "difference", "version", "work"]) and
      u64?(expected) and u64?(version) and is_boolean(changed) and
      version == expected + if(changed, do: 1, else: 0) and
      difference?(result["difference"]) and work?(result["work"])
  end

  def apply_result?(_result, _expected), do: false

  def valid_result?(result) when is_map(result) do
    exact_keys?(result, ["changed", "difference", "version", "work"]) and
      is_boolean(result["changed"]) and u64?(result["version"]) and
      difference?(result["difference"]) and work?(result["work"])
  end

  def valid_result?(_result), do: false

  defp difference?(difference) when is_map(difference) do
    Enum.sort(Map.keys(difference)) == [
      "added_products",
      "newly_blocked",
      "removed_products",
      "restored"
    ] and
      Enum.all?(Map.values(difference), &strings?/1)
  end

  defp difference?(_difference), do: false

  defp work?(work) when is_map(work) do
    Enum.sort(Map.keys(work)) == ["recomputed_parts", "recomputed_products", "visited_relations"] and
      Enum.all?(Map.values(work), &u64?/1)
  end

  defp work?(_work), do: false

  defp blocked?(blocked) when is_map(blocked),
    do: Enum.all?(blocked, fn {key, value} -> is_binary(key) and strings?(value) end)

  defp blocked?(_blocked), do: false
  defp strings?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
  defp strings?(_values), do: false
  defp u64?(value), do: is_integer(value) and value >= 0 and value <= @u64_max

  defp failure,
    do:
      {:error, %{"code" => "transport_failure", "detail" => "invalid CLI response schema/depth"}}
end
