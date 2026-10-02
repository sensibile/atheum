Code.require_file("lib/atheum/postgres.ex")
alias Atheum.Postgres
config = %{psql: System.find_executable("psql"), pg_url: "postgres://postgres@127.0.0.1:55440/atheum_decoy?dbname=atheum_cycle_test", timeout_ms: 10}
{:ok, "atheum_cycle_test"} = Postgres.query("SELECT current_database()", config)
IO.puts("CONFIRMED URL path atheum_decoy is ignored by libpq dbname=atheum_cycle_test; only dedicated fixture DB contacted")
start = System.monotonic_time(:millisecond)
{:ok, _} = Postgres.query("SELECT pg_sleep(0.25)", %{config | pg_url: "postgres://postgres@127.0.0.1:55440/atheum_cycle_test"})
elapsed = System.monotonic_time(:millisecond) - start
true = elapsed >= 250
IO.puts("CONFIRMED real PG elapsed_ms=#{elapsed}, config.timeout_ms=10")
payload = "'; DROP TABLE atheum_invocations; -- $(touch no-file)\\\n한글"
{:ok, output} = Postgres.query("SELECT json_build_object('value', #{Postgres.text(payload)})", %{config | pg_url: "postgres://postgres@127.0.0.1:55440/atheum_cycle_test"})
true = JSON.decode!(output)["value"] == payload
IO.puts("CONFIRMED SQL metacharacters, backslash, newline and Korean round-trip as literal text")
