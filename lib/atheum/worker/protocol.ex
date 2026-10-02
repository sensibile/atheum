defmodule Atheum.Worker.Protocol do
  @moduledoc "Pure one-job worker protocol. Only the registered Supplier Function is allowed."
  alias Atheum.{Core, Wire}
  @spec_name "supplier-set-active-v1"

  def ready(instance, generation),
    do: %{
      "type" => "ready",
      "instance" => instance,
      "instance_generation" => generation,
      "spec" => @spec_name
    }

  def job(row, instance) do
    %{
      "type" => "job",
      "instance" => instance,
      "invocation_id" => row["invocation_id"],
      "execution_id" => row["execution_id"],
      "attempt_id" => row["attempt_id"],
      "generation" => row["generation"],
      "request" => row["request"]["apply"]
    }
  end

  def plan(
        %{
          "type" => "job",
          "request" =>
            %{
              "request_id" => id,
              "expected_version" => version,
              "operations" => [%{"op" => "set_active", "id" => supplier, "active" => active}]
            } = request
        } = job
      ) do
    input = %{"supplier_id" => supplier, "active" => active, "expected_version" => version}

    if Core.validate(input) == :ok and valid_id?(id) and job_shape?(job) and
         Enum.sort(Map.keys(request)) == ["expected_version", "operations", "request_id"] do
      {:ok, job |> Map.put("type", "effect")}
    else
      failure()
    end
  end

  def plan(_job), do: failure()

  def result(job, %{
        "type" => "observation",
        "attempt_id" => attempt,
        "outcome" => outcome,
        "exit" => status
      }) do
    with true <- attempt == job["attempt_id"],
         validated <-
           Wire.response(outcome, status, %{"command" => "apply", "request" => job["request"]}),
         true <- validated_outcome?(validated, outcome) do
      {:ok,
       job
       |> Map.delete("request")
       |> Map.put("type", "result")
       |> Map.put("outcome", outcome)
       |> Map.put("exit", status)}
    else
      _other -> failure()
    end
  end

  def result(_job, _observation), do: failure()

  def observation(attempt, {:ok, result}),
    do: %{
      "type" => "observation",
      "attempt_id" => attempt,
      "outcome" => %{"ok" => true, "result" => %{"apply" => result}},
      "exit" => 0
    }

  def observation(attempt, {:error, error}),
    do: %{
      "type" => "observation",
      "attempt_id" => attempt,
      "outcome" => %{"ok" => false, "error" => error},
      "exit" => 2
    }

  defp validated_outcome?({:ok, _result}, %{"ok" => true}), do: true
  defp validated_outcome?({:error, error}, %{"ok" => false, "error" => error}), do: true
  defp validated_outcome?(_validated, _outcome), do: false

  defp job_shape?(job) do
    Enum.sort(Map.keys(job)) == [
      "attempt_id",
      "execution_id",
      "generation",
      "instance",
      "invocation_id",
      "request",
      "type"
    ] and
      Enum.all?(["attempt_id", "execution_id", "instance", "invocation_id"], &valid_id?(job[&1])) and
      is_integer(job["generation"]) and job["generation"] > 0
  end

  defp valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and String.trim(id) != ""

  defp failure,
    do: {:error, %{"code" => "worker_protocol", "detail" => "invalid one-job protocol"}}
end
