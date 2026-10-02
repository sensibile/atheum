defmodule Atheum.Worker.Docker do
  @moduledoc "Docker shell restricted to persisted project instances and the fixed image."
  alias Atheum.{ProcessIO, Wire}

  def verify(spec, config) do
    with {:ok, bytes} <-
           command(["image", "inspect", "--format", "{{json .}}", spec["image_id"]], config),
         {:ok, image} <- Wire.decode(bytes),
         true <- image["Id"] == spec["image_id"],
         true <- image["Config"]["Labels"]["org.acropolis.atheum.source"] == spec["source_sha256"],
         true <- image["Config"]["Labels"]["org.acropolis.atheum.worker_spec"] == spec["spec"] do
      :ok
    else
      _other -> failure("fixed image identity/label mismatch")
    end
  end

  def create(instance, config) do
    args = [
      "create",
      "--name",
      instance["instance_name"],
      "--restart=no",
      "--init",
      "--network=none",
      "--read-only",
      "--user=65534:65534",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--pids-limit=64",
      "--memory=128m",
      "--memory-swap=128m",
      "--cpus=0.5",
      "--tmpfs=/tmp:rw,noexec,nosuid,size=16m",
      "--label",
      "org.acropolis.atheum.worker=supplier-set-active-v1",
      "--label",
      "org.acropolis.atheum.owner=" <> instance["owner_token"],
      "--label",
      "org.acropolis.atheum.instance_generation=" <> to_string(instance["instance_generation"]),
      "--interactive",
      instance["image_id"],
      instance["instance_name"],
      to_string(instance["instance_generation"])
    ]

    command(args, config)
  end

  def inspect_owned(instance, config) do
    with {:ok, bytes} <-
           command(["inspect", "--format", "{{json .}}", instance["instance_name"]], config),
         {:ok, object} <- Wire.decode(bytes),
         true <- object["Image"] == instance["image_id"],
         true <-
           object["Config"]["Labels"]["org.acropolis.atheum.owner"] == instance["owner_token"],
         true <-
           object["Config"]["Labels"]["org.acropolis.atheum.worker"] == "supplier-set-active-v1",
         true <-
           object["Config"]["Labels"]["org.acropolis.atheum.instance_generation"] ==
             to_string(instance["instance_generation"]),
         true <- is_nil(instance["container_id"]) or instance["container_id"] == object["Id"] do
      {:ok, object}
    else
      _other -> failure("container ownership/identity unconfirmed")
    end
  end

  def absent?(instance, config) do
    case command(
           [
             "container",
             "ls",
             "-a",
             "--filter",
             "name=^/" <> instance["instance_name"] <> "$",
             "--format",
             "{{.ID}}"
           ],
           config
         ) do
      {:ok, ""} -> true
      _other -> false
    end
  end

  def remove(instance, config) do
    with {:ok, object} <- inspect_owned(instance, config),
         {:ok, _output} <- command(["rm", "--force", object["Id"]], config),
         true <- absent?(instance, config) do
      {:ok, %{"container_id" => object["Id"], "removed" => true, "worker_stop_confirmed" => true}}
    else
      _other -> failure("owned container removal unconfirmed")
    end
  end

  def command(args, config) do
    case ProcessIO.run(config.docker, args, Map.get(config, :docker_timeout_ms, 10_000)) do
      {:ok, bytes, 0} -> {:ok, String.trim(bytes)}
      {:ok, bytes, _status} -> failure(String.trim(bytes))
      {:error, error} -> {:error, error}
    end
  end

  defp failure(detail), do: {:error, %{"code" => "worker_docker", "detail" => detail}}
end
