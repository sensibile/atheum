defmodule Atheum do
  @moduledoc "Local experimental service boundary for one Action. No production authorization."
  alias Atheum.{Akashic, Core, Postgres}
  alias Atheum.Worker.Manager

  def submit(key, input, config, opts \\ []) do
    with :ok <- Core.validate(input),
         :ok <- valid_key(key) do
      deadline = Keyword.get(opts, :deadline_ms)
      safe_retry = Keyword.get(opts, :safe_retry, false)

      if is_integer(deadline) and deadline > System.system_time(:millisecond) and
           is_boolean(safe_retry) do
        target = target(config)

        fingerprint = %{
          "action" => "supplier.set_active.v1",
          "input" => input,
          "target" => target,
          "deadline_ms" => deadline,
          "safe_retry" => safe_retry,
          "context" => "local-experiment"
        }

        request = %{
          "fingerprint" => fingerprint,
          "deadline_ms" => deadline,
          "safe_retry" => safe_retry,
          "target" => target,
          "apply" => %{
            "request_id" => Postgres.id(),
            "expected_version" => input["expected_version"],
            "operations" => [
              %{"op" => "set_active", "id" => input["supplier_id"], "active" => input["active"]}
            ]
          }
        }

        Postgres.submit(key, request, config)
      else
        {:error, :invalid_options}
      end
    end
  end

  def get(id, config), do: Postgres.get(id, config)
  def history(id, config, opts \\ []), do: Postgres.history(id, config, opts)

  def run(id, config, opts \\ []) do
    with {:ok, row} <- get(id, config),
         :ok <- startable(row, config),
         {:ok, claimed} <- claim(id, "status='accepted' AND NOT cancel_requested", config) do
      perform(claimed, config, opts)
    end
  end

  def recover(id, config, opts \\ []) do
    with {:ok, row} <- get(id, config),
         :ok <- Core.recoverable(row, System.system_time(:millisecond), target(config)),
         {:ok, claimed} <-
           claim(
             id,
             "status IN ('running','unresolved') AND NOT cancel_requested AND generation=#{row["generation"]}",
             config
           ) do
      perform(claimed, config, opts)
    end
  end

  def cancel(id, config) do
    Postgres.transition(
      id,
      "true",
      "cancel_requested=true,status=CASE WHEN status='accepted' THEN 'stopped' ELSE status END,stop_confirmed=CASE WHEN status='accepted' THEN true ELSE stop_confirmed END",
      "cancel_requested",
      %{"reason" => "user_request"},
      config
    )
  end

  defp claim(id, condition, config) do
    attempt = Postgres.id()

    Postgres.transition(
      id,
      condition,
      "status='running',attempt_id=#{Postgres.text(attempt)},generation=generation+1,effect_certainty='unknown',result=NULL,error=NULL",
      "call_intent",
      %{"attempt_id" => attempt},
      config
    )
  end

  defp perform(row, config, opts) do
    with {:ok, current} <- get(row["invocation_id"], config) do
      if send_blocked?(row, current) do
        finish_blocked(row, config)
      else
        observe_call(row, config, opts)
      end
    end
  end

  defp send_blocked?(row, current) do
    current["generation"] != row["generation"] or current["cancel_requested"] or
      System.system_time(:millisecond) >= row["request"]["deadline_ms"]
  end

  defp finish_blocked(%{"generation" => 1} = row, config),
    do: finish(row, {"stopped", "not_started", nil, %{"code" => "start_blocked"}}, config, true)

  defp finish_blocked(row, config),
    do:
      finish(row, {"unresolved", "unknown", nil, %{"code" => "recovery_blocked"}}, config, false)

  defp observe_call(row, config, opts) do
    remaining = row["request"]["deadline_ms"] - System.system_time(:millisecond)

    outcome =
      case Keyword.get(opts, :runner, :local) do
        :local ->
          Akashic.apply(%{"command" => "apply", "request" => row["request"]["apply"]}, %{
            config
            | timeout_ms: min(config.timeout_ms, remaining)
          })

        {:docker, token} ->
          Manager.execute(row, token, config, opts)

        _other ->
          {:error, %{"code" => "invalid_configuration", "detail" => "unknown runner"}}
      end

    Keyword.get(opts, :after_effect, fn _outcome -> :ok end).(outcome)
    finish(row, Core.completion(outcome), config, false)
  end

  defp finish(row, {status, certainty, result, error}, config, stopped) do
    # A recovered successful request may still be a no-op; result.changed expresses that.
    outcome =
      Postgres.transition(
        row["invocation_id"],
        "generation=#{row["generation"]} AND attempt_id=#{Postgres.text(row["attempt_id"])}",
        "status=#{Postgres.text(status)},effect_certainty=#{Postgres.text(certainty)},result=#{Postgres.value(result)},error=#{Postgres.value(error)},stop_confirmed=#{stopped}",
        "attempt_observed",
        %{
          "status" => status,
          "effect_certainty" => certainty,
          "result" => result,
          "error" => error
        },
        config
      )

    case outcome do
      {:error, :transition_conflict} ->
        evidence = %{
          "status" => status,
          "effect_certainty" => certainty,
          "result" => result,
          "error" => error
        }

        case Postgres.query(
               "INSERT INTO atheum_events(invocation_id,attempt_id,kind,data) VALUES(#{Postgres.text(row["invocation_id"])},#{Postgres.text(row["attempt_id"])},'stale_attempt_observed',#{Postgres.value(evidence)})",
               config
             ) do
          {:ok, _} -> {:error, :stale_attempt}
          failure -> failure
        end

      other ->
        other
    end
  end

  defp startable(row, config) do
    cond do
      row["status"] != "accepted" ->
        {:error, :not_accepted}

      row["request"]["target"] != target(config) ->
        {:error, :target_changed}

      System.system_time(:millisecond) >= row["request"]["deadline_ms"] ->
        {:error, :deadline_expired}

      true ->
        :ok
    end
  end

  defp target(config),
    do: %{
      "db" => Path.expand(config.akashic_db),
      "identity" => config.akashic_identity,
      "storage" => Atom.to_string(config.storage)
    }

  defp valid_key(key) when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= 128,
    do: if(String.valid?(key) and String.trim(key) != "", do: :ok, else: {:error, :invalid_key})

  defp valid_key(_), do: {:error, :invalid_key}
end
