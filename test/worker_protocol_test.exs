defmodule Atheum.WorkerProtocolTest do
  use ExUnit.Case, async: true
  alias Atheum.Worker.Protocol

  test "only fixed Function job and matching attempt may produce a result" do
    row = %{
      "invocation_id" => "i",
      "execution_id" => "e",
      "attempt_id" => "a",
      "generation" => 1,
      "request" => %{
        "apply" => %{
          "request_id" => "r",
          "expected_version" => 1,
          "operations" => [%{"op" => "set_active", "id" => "S1", "active" => false}]
        }
      }
    }

    job = Protocol.job(row, "worker")
    assert {:ok, effect} = Protocol.plan(job)
    assert effect["type"] == "effect"
    assert {:error, _} = Protocol.plan(Map.put(job, "command", "arbitrary"))

    assert {:error, _} =
             Protocol.plan(put_in(job, ["request", "operations"], [%{"op" => "delete"}]))

    rejection =
      Protocol.observation("a", {:error, %{"code" => "version_conflict", "detail" => "conflict"}})

    assert {:ok, result} = Protocol.result(job, rejection)
    assert result["attempt_id"] == "a"
    assert {:error, _} = Protocol.result(job, Map.put(rejection, "attempt_id", "old"))
    assert {:error, _} = Protocol.result(job, put_in(rejection, ["outcome", "result"], nil))
    assert {:error, _} = Protocol.result(job, Map.put(rejection, "exit", 0))
  end
end
