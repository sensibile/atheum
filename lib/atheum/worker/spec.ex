defmodule Atheum.Worker.Spec do
  @moduledoc "The one project-owned image, pinned by content ID and build-source digest."
  @files [
    "worker/Dockerfile",
    "worker/main.exs",
    "lib/atheum/core.ex",
    "lib/atheum/wire.ex",
    "lib/atheum/worker/protocol.ex"
  ]
  def load do
    root = Path.expand("../../..", __DIR__)

    with {:ok, bytes} <- File.read(Path.join(root, "worker/image.json")),
         {:ok,
          %{"spec" => "supplier-set-active-v1", "image_id" => id, "source_sha256" => source} =
            spec} <- JSON.decode(bytes),
         true <- Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, id),
         {:ok, parts} <- sources(root),
         true <- Base.encode16(:crypto.hash(:sha256, parts), case: :lower) == source do
      {:ok, spec}
    else
      _other ->
        {:error,
         %{
           "code" => "worker_image",
           "detail" => "fixed image missing or stale; run scripts/build-worker"
         }}
    end
  end

  defp sources(root) do
    Enum.reduce_while(@files, {:ok, []}, fn name, {:ok, parts} ->
      case File.read(Path.join(root, name)) do
        {:ok, bytes} -> {:cont, {:ok, parts ++ [name, <<0>>, bytes]}}
        failure -> {:halt, failure}
      end
    end)
  end
end
