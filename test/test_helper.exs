ExUnit.start(
  exclude: if(System.get_env("ATHEUM_ACCEPTANCE_EVENTS"), do: [:test], else: [:integration])
)

if System.get_env("ATHEUM_ACCEPTANCE_EVENTS") do
  Code.require_file("support/acceptance_formatter_helper.exs", __DIR__)
  ExUnit.configure(formatters: [ExUnit.CLIFormatter, Atheum.AcceptanceFormatter])
end
