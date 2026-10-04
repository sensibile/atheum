defmodule Atheum.AcceptanceFormatter do
  @moduledoc false
  use GenServer

  def init(_opts), do: {:ok, []}

  def handle_cast({:test_finished, test}, events) do
    case test.tags[:acceptance] do
      nil ->
        {:noreply, events}

      id ->
        status = if test.state == nil, do: "PASS", else: "FAIL"
        event = %{"id" => id, "status" => status, "test" => Atom.to_string(test.name)}
        {:noreply, [event | events]}
    end
  end

  def handle_cast({:suite_finished, _times}, events) do
    File.write!(System.fetch_env!("ATHEUM_ACCEPTANCE_EVENTS"), JSON.encode!(Enum.reverse(events)))
    {:noreply, events}
  end

  def handle_cast(_event, events), do: {:noreply, events}
end
