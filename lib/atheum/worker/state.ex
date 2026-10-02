defmodule Atheum.Worker.State do
  @moduledoc "Durable capacity=1 reservation and distinct worker-instance/job-attempt observations."
  alias Atheum.Postgres

  def reserve(invocation, config) do
    token = Postgres.id()

    sql =
      "INSERT INTO atheum_worker_slots(slot,owner_token,owner_vm,invocation_id) VALUES('local',#{Postgres.text(token)},#{Postgres.text(System.pid())},#{Postgres.text(invocation)}) ON CONFLICT(slot) DO NOTHING RETURNING owner_token"

    case Postgres.query(sql, config) do
      {:ok, ^token} -> {:ok, token}
      {:ok, ""} -> {:error, :capacity_busy}
      failure -> failure
    end
  end

  def slot(config),
    do: one("SELECT row_to_json(s) FROM atheum_worker_slots s WHERE slot='local'", config)

  def release(token, config),
    do:
      Postgres.query(
        "DELETE FROM atheum_worker_slots WHERE slot='local' AND owner_token=#{Postgres.text(token)}",
        config
      )

  def plan(row, token, spec, config) do
    name = "atheum-worker-" <> Postgres.id()

    sql =
      "INSERT INTO atheum_worker_instances(instance_name,owner_token,invocation_id,execution_id,attempt_id,job_generation,image_id,phase) VALUES(#{Postgres.text(name)},#{Postgres.text(token)},#{Postgres.text(row["invocation_id"])},#{Postgres.text(row["execution_id"])},#{Postgres.text(row["attempt_id"])},#{row["generation"]},#{Postgres.text(spec["image_id"])},'create_intent') RETURNING row_to_json(atheum_worker_instances)"

    one(sql, config)
  end

  def instance(name, config),
    do:
      one(
        "SELECT row_to_json(i) FROM atheum_worker_instances i WHERE instance_name=#{Postgres.text(name)}",
        config
      )

  def for_owner(token, config),
    do:
      one(
        "SELECT row_to_json(i) FROM atheum_worker_instances i WHERE owner_token=#{Postgres.text(token)} ORDER BY instance_generation DESC LIMIT 1",
        config
      )

  def record(instance, phase, data, config) do
    container =
      if data["container_id"],
        do: ",container_id=#{Postgres.text(data["container_id"])}",
        else: ""

    sql =
      "UPDATE atheum_worker_instances SET phase=#{Postgres.text(phase)},observations=observations || #{Postgres.value([%{"phase" => phase, "data" => data}])},updated_at=clock_timestamp()#{container} WHERE instance_name=#{Postgres.text(instance["instance_name"])} AND owner_token=#{Postgres.text(instance["owner_token"])} RETURNING row_to_json(atheum_worker_instances)"

    one(sql, config)
  end

  def owned?(token, config) do
    case slot(config) do
      {:ok, %{"owner_token" => ^token}} -> true
      _other -> false
    end
  end

  defp one(sql, config) do
    case Postgres.query(sql, config) do
      {:ok, ""} -> {:error, :not_found}
      {:ok, bytes} -> {:ok, JSON.decode!(bytes)}
      failure -> failure
    end
  end
end
