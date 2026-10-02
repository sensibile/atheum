defmodule Atheum.CoreTest do
  use ExUnit.Case, async: true
  alias Atheum.Core

  test "strict Function input" do
    assert :ok =
             Core.validate(%{"supplier_id" => "S1", "active" => false, "expected_version" => 1})

    for input <- [
          %{},
          %{"supplier_id" => "S1", "active" => false, "expected_version" => -1},
          %{"supplier_id" => "S1", "active" => false, "expected_version" => 1, "extra" => true}
        ] do
      assert {:error, :invalid_input} = Core.validate(input)
    end
  end

  test "timeout and transport failure never prove absence" do
    for code <- ["timeout", "transport_failure", "storage_failure", "request_conflict"] do
      assert {"unresolved", "unknown", nil, _} = Core.completion({:error, %{"code" => code}})
    end
  end

  test "confirmed rejection and no-op have separate meanings" do
    assert {"failed", "confirmed_absent", nil, _} =
             Core.completion({:error, %{"code" => "version_conflict"}})

    assert {"succeeded", "confirmed_absent", _, nil} =
             Core.completion({:ok, result(false)})

    assert {"succeeded", "confirmed_present", _, nil} =
             Core.completion({:ok, result(true)})
  end

  test "recovery requires opt-in, same target and unexpired uncancelled request" do
    target = %{"db" => "fixture"}

    row = %{
      "status" => "unresolved",
      "cancel_requested" => false,
      "request" => %{"deadline_ms" => 100, "target" => target, "safe_retry" => true}
    }

    assert :ok = Core.recoverable(row, 99, target)
    assert {:error, :deadline_expired} = Core.recoverable(row, 100, target)
    assert {:error, :target_changed} = Core.recoverable(row, 99, %{})

    assert {:error, :cancel_requested} =
             Core.recoverable(Map.put(row, "cancel_requested", true), 99, target)

    assert {:error, :retry_disabled} =
             Core.recoverable(put_in(row, ["request", "safe_retry"], false), 99, target)

    assert {:error, :request_conflict} =
             Core.recoverable(Map.put(row, "error", %{"code" => "request_conflict"}), 99, target)
  end

  defp result(changed) do
    %{
      "version" => 1,
      "changed" => changed,
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
