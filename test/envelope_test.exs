defmodule Atheum.EnvelopeTest do
  use ExUnit.Case, async: true
  alias Atheum.{Core, Wire}
  @request %{"command" => "apply", "request" => %{"expected_version" => 1}}
  @error %{"code" => "invalid_input", "detail" => "fixture rejection"}

  test "success and rejection envelopes are exclusive for either exit direction" do
    result = valid_result()
    success = %{"ok" => true, "result" => %{"apply" => result}}
    rejection = %{"ok" => false, "error" => @error}
    assert {:ok, ^result} = Wire.response(success, 0, @request)
    assert {:error, @error} = Wire.response(rejection, 2, @request)

    for {wire, status} <- [
          {Map.put(success, "error", @error), 0},
          {Map.put(success, "error", nil), 0},
          {Map.put(rejection, "result", %{"apply" => result}), 2},
          {Map.put(rejection, "result", nil), 2},
          {Map.put(success, "ok", false), 2},
          {Map.put(rejection, "ok", true), 0},
          {success, 2},
          {rejection, 0},
          {rejection, 1}
        ] do
      assert_unknown(wire, status)
    end
  end

  test "missing, unknown and mistyped envelope fields are not rejection evidence" do
    for wire <- [
          nil,
          [],
          true,
          %{},
          %{"ok" => false},
          %{"error" => @error},
          %{"ok" => "false", "error" => @error},
          %{"ok" => false, "error" => nil},
          %{"ok" => false, "error" => []},
          %{"ok" => false, "error" => %{"code" => "invalid_input"}},
          %{"ok" => false, "error" => %{"detail" => "missing code"}},
          %{"ok" => false, "error" => %{"code" => 1, "detail" => "typed"}},
          %{"ok" => false, "error" => %{"code" => "invalid_input", "detail" => false}},
          %{"ok" => false, "error" => %{"code" => " ", "detail" => "empty code"}},
          %{"ok" => false, "error" => Map.put(@error, "result", %{})},
          %{"ok" => false, "error" => @error, "extra" => true}
        ] do
      assert_unknown(wire, 2)
    end

    for wire <- [
          %{"ok" => true},
          %{"result" => %{"apply" => valid_result()}},
          %{"ok" => 1, "result" => %{"apply" => valid_result()}},
          %{"ok" => true, "result" => nil},
          %{"ok" => true, "result" => []},
          %{"ok" => true, "result" => %{"apply" => valid_result()}, "extra" => true},
          %{"ok" => true, "result" => %{"apply" => valid_result(), "error" => @error}},
          %{"ok" => true, "result" => %{"apply" => Map.put(valid_result(), "error", @error)}},
          %{"ok" => true, "result" => %{"apply" => valid_result(), "write_work" => false}}
        ] do
      assert_unknown(wire, 0)
    end
  end

  test "impact and validate use the same exclusive outer contract" do
    impact = %{
      "ok" => true,
      "result" => %{
        "blocked_by_product" => %{},
        "version" => 1,
        "work" => %{"recomputed_parts" => 0, "recomputed_products" => 0, "visited_relations" => 0}
      }
    }

    validate = %{"ok" => true, "result" => %{"valid" => true, "version" => 1}}

    for {wire, request} <- [
          {impact, %{"command" => "impact", "version" => 1}},
          {validate, %{"command" => "validate"}}
        ] do
      assert {:ok, _result} = Wire.response(wire, 0, request)

      for {bad, status} <- [
            {Map.put(wire, "error", @error), 0},
            {wire |> Map.put("ok", false) |> Map.put("error", @error), 2},
            {Map.update!(wire, "result", &Map.put(&1, "extra", true)), 0}
          ] do
        assert {:error, %{"code" => "transport_failure"}} = Wire.response(bad, status, request)
      end
    end
  end

  test "duplicate keys and multiple JSON values are ambiguous even if one decoding would reject" do
    for bytes <- [
          ~s({"ok":true,"ok":false,"error":{"code":"invalid_input","detail":"x"}}),
          ~s({"ok":false,"error":{"code":"storage_failure","code":"invalid_input","detail":"x"}}),
          ~s({"ok":false,"error":{"code":"invalid_input","detail":"x"}} {}),
          ~s({"ok":false,"error":{"code":"invalid_input","detail":"x"}} trailing)
        ] do
      assert {:error, %{"code" => "transport_failure"} = error} = Wire.decode(bytes)
      assert {"unresolved", "unknown", nil, ^error} = Core.completion({:error, error})
    end
  end

  defp assert_unknown(wire, status) do
    assert {:error, %{"code" => "transport_failure"} = error} =
             Wire.response(wire, status, @request)

    assert {"unresolved", "unknown", nil, ^error} = Core.completion({:error, error})
  end

  defp valid_result do
    %{
      "version" => 2,
      "changed" => true,
      "difference" => %{
        "added_products" => [],
        "newly_blocked" => [],
        "removed_products" => [],
        "restored" => []
      },
      "work" => %{"recomputed_parts" => 0, "recomputed_products" => 0, "visited_relations" => 0}
    }
  end
end
