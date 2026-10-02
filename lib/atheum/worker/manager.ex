defmodule Atheum.Worker.Manager do
  @moduledoc "Single local lifecycle owner. Worker replacement never implicitly retries a job."
  alias Atheum.{Akashic, Postgres}
  alias Atheum.Worker.{Docker, Protocol, Session, Spec, State}
  @owner_name {__MODULE__, :local}

  def run(id, config, opts \\ []), do: dispatch(:run, id, config, opts)
  def recover(id, config, opts \\ []), do: dispatch(:recover, id, config, opts)

  defp dispatch(operation, id, config, opts) do
    with_owner(fn ->
      with {:ok, spec} <- Spec.load(),
           :ok <- Docker.verify(spec, config),
           {:ok, token} <- State.reserve(id, config) do
        try do
          apply(Atheum, operation, [id, config, Keyword.put(opts, :runner, {:docker, token})])
        after
          release_if_reclaimed(token, config)
        end
      end
    end)
  end

  def execute(row, token, config, opts) do
    with {:ok, spec} <- Spec.load(),
         true <- State.owned?(token, config),
         {:ok, instance} <- State.plan(row, token, spec, config) do
      launch(row, instance, config, opts)
    else
      false -> failure("dispatch ownership lost")
      error -> error
    end
  end

  defp launch(row, instance, config, opts) do
    result =
      with {:ok, id} <- Docker.create(instance, config),
           {:ok, created} <- State.record(instance, "created", %{"container_id" => id}, config),
           :ok <- hook(opts, :after_container_created, created),
           {:ok, _object} <- Docker.inspect_owned(created, config),
           {:ok, session} <- Session.open(created, config) do
        try do
          dialogue(row, created, session, config, opts)
        after
          Session.close(session)
        end
      end

    case reclaim_instance(instance, config) do
      {:ok, _proof} -> result
      _unconfirmed -> failure("container reclamation unconfirmed; capacity remains reserved")
    end
  end

  defp dialogue(row, instance, session, config, opts) do
    ready = Protocol.ready(instance["instance_name"], instance["instance_generation"])
    job = Protocol.job(row, instance["instance_name"])

    with {:ok, ^ready, session} <- Session.message(session),
         {:ok, _ready} <- State.record(instance, "ready", ready, config),
         :ok <- hook(opts, :after_worker_ready, instance),
         :ok <- eligible(row, instance, config),
         :ok <- Session.send_message(session, job),
         {:ok, effect, session} <- Session.message(session),
         {:ok, ^effect} <- Protocol.plan(job),
         :ok <- eligible(row, instance, config),
         {:ok, _progress} <-
           State.record(instance, "executing", %{"attempt_id" => row["attempt_id"]}, config) do
      observe_effect(row, instance, job, session, config, opts)
    else
      error -> normalize(error)
    end
  end

  defp observe_effect(row, instance, job, session, config, opts) do
    remaining = row["request"]["deadline_ms"] - System.system_time(:millisecond)

    outcome =
      Akashic.apply(%{"command" => "apply", "request" => job["request"]}, %{
        config
        | timeout_ms: min(config.timeout_ms, remaining)
      })

    observation = Protocol.observation(row["attempt_id"], outcome)

    with {:ok, _observed} <- State.record(instance, "effect_observed", observation, config),
         :ok <- hook(opts, :after_host_effect, instance),
         :ok <- Session.send_message(session, observation),
         {:ok, expected} <- Protocol.result(job, observation),
         {:ok, ^expected, session} <- Session.message(session),
         {:ok, _result} <- State.record(instance, "result_received", expected, config),
         :ok <- hook(opts, :after_worker_result, instance),
         :ok <- Session.exited(session),
         {:ok, object} <- Docker.inspect_owned(instance, config),
         true <- object["State"]["Running"] == false and object["State"]["ExitCode"] == 0,
         {:ok, _exited} <- State.record(instance, "exited", %{"exit_code" => 0}, config) do
      outcome
    else
      error -> normalize(error)
    end
  end

  defp eligible(row, instance, config) do
    with true <- State.owned?(instance["owner_token"], config),
         {:ok, current} <- Atheum.get(row["invocation_id"], config),
         true <-
           current["attempt_id"] == row["attempt_id"] and
             current["generation"] == row["generation"],
         true <- not current["cancel_requested"],
         true <- System.system_time(:millisecond) < row["request"]["deadline_ms"] do
      :ok
    else
      _other -> failure("job ownership/cancel/deadline blocks dispatch")
    end
  end

  def reconcile(config) do
    with_owner(fn ->
      case State.slot(config) do
        {:error, :not_found} -> {:ok, :idle}
        {:ok, slot} -> reconcile_slot(slot, config)
        failure -> failure
      end
    end)
  end

  defp reconcile_slot(slot, config) do
    if owner_down?(slot) do
      case State.for_owner(slot["owner_token"], config) do
        {:error, :not_found} -> State.release(slot["owner_token"], config)
        {:ok, instance} -> reconcile_job(slot, instance, config)
        failure -> failure
      end
    else
      failure("previous manager VM may still be alive")
    end
  end

  defp reconcile_job(slot, instance, config) do
    with {:ok, proof} <- reclaim_instance(instance, config),
         {:ok, _record} <- mark_orphan(instance, config),
         {:ok, _released} <- State.release(slot["owner_token"], config) do
      {:ok, proof}
    end
  end

  defp mark_orphan(instance, config) do
    case Postgres.transition(
           instance["invocation_id"],
           "status IN ('running','unresolved') AND generation=#{instance["job_generation"]} AND attempt_id=#{Postgres.text(instance["attempt_id"])}",
           "status='unresolved',effect_certainty='unknown',error=#{Postgres.value(%{"code" => "worker_orphan", "detail" => "worker reclaimed; effect not disproved"})}",
           "worker_orphan_reclaimed",
           %{"instance_name" => instance["instance_name"]},
           config
         ) do
      {:error, :transition_conflict} -> {:ok, :state_already_changed}
      other -> other
    end
  end

  defp reclaim_instance(instance, config) do
    with {:ok, current} <- State.instance(instance["instance_name"], config) do
      reclaim_current(current, config)
    end
  end

  defp reclaim_current(%{"phase" => "removed"} = instance, _config),
    do: {:ok, %{"instance_name" => instance["instance_name"], "removed" => true}}

  defp reclaim_current(instance, config) do
    case Docker.remove(instance, config) do
      {:ok, proof} -> State.record(instance, "removed", proof, config)
      failure -> reclaim_absent(instance, config, failure)
    end
  end

  defp reclaim_absent(instance, config, failure) do
    # Unknown create may still complete later; absence alone cannot release that slot.
    if not is_nil(instance["container_id"]) and Docker.absent?(instance, config) do
      State.record(instance, "removed", %{"removed" => true, "worker_absent" => true}, config)
    else
      failure
    end
  end

  defp release_if_reclaimed(token, config) do
    case State.for_owner(token, config) do
      {:error, :not_found} -> State.release(token, config)
      {:ok, %{"phase" => "removed"}} -> State.release(token, config)
      _unresolved -> :ok
    end
  end

  defp owner_down?(%{"owner_vm" => vm}) do
    if vm == System.pid() do
      true
    else
      case System.cmd("/bin/ps", ["-p", vm, "-o", "pid="]) do
        {"", 1} -> true
        _other -> false
      end
    end
  end

  defp with_owner(callback) do
    if :global.register_name(@owner_name, self()) == :yes do
      try do
        callback.()
      after
        :global.unregister_name(@owner_name)
      end
    else
      {:error, :capacity_busy}
    end
  end

  defp hook(opts, name, value), do: Keyword.get(opts, name, fn _value -> :ok end).(value)
  defp normalize({:error, _error} = error), do: error
  defp normalize(_invalid), do: failure("worker protocol/exit mismatch")
  defp failure(detail), do: {:error, %{"code" => "worker_lost", "detail" => detail}}
end
