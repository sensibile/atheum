defmodule Atheum.CycleIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  alias Atheum.{Akashic, Postgres}

  setup do
    root = Path.join(System.tmp_dir!(), "atheum-" <> Postgres.id())
    File.mkdir_p!(root)

    config = %{
      psql: System.find_executable("psql"),
      pg_url: System.fetch_env!("ATHEUM_TEST_PG_URL"),
      binary: System.fetch_env!("AKASHIC_BINARY"),
      akashic_db: Path.join(root, "db"),
      akashic_identity: Postgres.id(),
      storage: :snapshot,
      timeout_ms: 10_000
    }

    assert {:ok, _} = Postgres.setup(config)

    seed = %{
      "command" => "apply",
      "request" => %{
        "request_id" => "seed",
        "expected_version" => 0,
        "operations" => [
          %{
            "op" => "add_object",
            "id" => "S1",
            "object" => %{"kind" => "supplier", "active" => true}
          },
          %{"op" => "add_object", "id" => "B", "object" => %{"kind" => "part"}},
          %{"op" => "add_object", "id" => "P", "object" => %{"kind" => "product"}},
          %{
            "op" => "add_relation",
            "relation" => %{"kind" => "supplies", "from" => "S1", "to" => "B"}
          },
          %{
            "op" => "add_relation",
            "relation" => %{"kind" => "requires", "from" => "P", "to" => "B"}
          }
        ]
      }
    }

    assert {:ok, %{"version" => 1}} = Akashic.apply(seed, config)
    opts = [deadline_ms: System.system_time(:millisecond) + 60_000, safe_retry: true]

    on_exit(fn ->
      # Delete only this test's rows and temporary directory, never shared production data.
      assert {:ok, _} =
               Postgres.query(
                 "BEGIN; DELETE FROM atheum_events WHERE invocation_id IN (SELECT invocation_id FROM atheum_invocations WHERE request->'target'->>'identity'=#{Postgres.text(config.akashic_identity)}); DELETE FROM atheum_invocations WHERE request->'target'->>'identity'=#{Postgres.text(config.akashic_identity)}; COMMIT;",
                 config
               )

      File.rm_rf!(root)
    end)

    %{config: config, opts: opts, root: root}
  end

  defp submit(config, opts, key \\ Postgres.id()) do
    assert {:ok, row} =
             Atheum.submit(
               key,
               %{"supplier_id" => "S1", "active" => false, "expected_version" => 1},
               config,
               opts
             )

    row
  end

  defp impact(config, version) do
    assert {:ok, result} =
             Akashic.apply(
               %{"command" => "impact", "version" => version, "method" => "full"},
               config
             )

    result["blocked_by_product"]
  end

  test "real Function, durable result, independent graph answer and no extra replay version", %{
    config: c,
    opts: opts
  } do
    row = submit(c, opts)
    assert {:ok, done} = Atheum.run(row["invocation_id"], c)
    assert done["status"] == "succeeded"
    assert done["result"]["version"] == 2
    assert done["result"]["changed"]
    assert impact(c, 2) == %{"P" => ["B"]}

    assert {:ok, replay} =
             Akashic.apply(%{"command" => "apply", "request" => row["request"]["apply"]}, c)

    assert replay == done["result"]

    assert {:ok, %{"version" => 3}} =
             Akashic.apply(
               %{
                 "command" => "apply",
                 "request" => %{
                   "request_id" => "advance",
                   "expected_version" => 2,
                   "operations" => [
                     %{
                       "op" => "add_object",
                       "id" => "S2",
                       "object" => %{"kind" => "supplier", "active" => true}
                     }
                   ]
                 }
               },
               c
             )

    {raw, 0} =
      System.cmd(c.binary, [
        "--db",
        c.akashic_db,
        "--json",
        JSON.encode!(%{"command" => "apply", "request" => row["request"]["apply"]})
      ])

    wire = JSON.decode!(raw)
    assert wire["result"]["apply"] == done["result"]
    assert wire["result"]["write_work"]["logical_writes"] == 0
    assert impact(c, 3) == %{"P" => ["B"]}
    assert {:ok, fetched} = Atheum.get(row["invocation_id"], c)
    assert fetched == done
    # Read persisted state from a fresh BEAM VM, independent of the test process.
    beam_path = Path.join([File.cwd!(), "_build", "test", "lib", "atheum", "ebin"])

    fresh_code =
      "config = " <>
        inspect(%{psql: c.psql, pg_url: c.pg_url}) <>
        "; {:ok, row} = Atheum.get(" <>
        inspect(row["invocation_id"]) <> ", config); IO.puts(JSON.encode!(row))"

    {fresh_output, 0} =
      System.cmd(System.find_executable("elixir"), ["-pa", beam_path, "-e", fresh_code])

    assert JSON.decode!(String.trim(fresh_output)) == done

    assert {:ok, independent} =
             Postgres.query(
               "SELECT json_build_object('status',status,'version',result->'version','count',(SELECT count(*) FROM atheum_events e WHERE e.invocation_id=i.invocation_id)) FROM atheum_invocations i WHERE invocation_id=#{Postgres.text(row["invocation_id"])}",
               c
             )

    assert JSON.decode!(independent) == %{"status" => "succeeded", "version" => 2, "count" => 3}
    assert {:ok, history} = Atheum.history(row["invocation_id"], c)
    assert Enum.map(history, & &1["kind"]) == ["accepted", "call_intent", "attempt_observed"]
    assert Enum.uniq(Enum.map(history, & &1["invocation_id"])) == [row["invocation_id"]]
  end

  test "concurrent duplicate acceptance and conflicting input", %{config: c, opts: opts} do
    key = Postgres.id()
    tasks = for _ <- 1..4, do: Task.async(fn -> submit(c, opts, key) end)
    rows = Enum.map(tasks, &Task.await(&1, 15_000))
    assert length(Enum.uniq(Enum.map(rows, & &1["invocation_id"]))) == 1

    assert {:error, :acceptance_conflict} =
             Atheum.submit(
               key,
               %{"supplier_id" => "S1", "active" => true, "expected_version" => 1},
               c,
               opts
             )

    assert {:ok, history} = Atheum.history(hd(rows)["invocation_id"], c)
    assert length(history) == 1
  end

  test "real success then worker death before journal completion recovers exact receipt", %{
    config: c,
    opts: opts
  } do
    row = submit(c, opts)
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Atheum.run(row["invocation_id"], c,
          after_effect: fn outcome ->
            send(parent, {:effect_committed, outcome})

            receive do
              :never -> :ok
            end
          end
        )
      end)

    assert_receive {:effect_committed, {:ok, first}}, 15_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert {:ok, pending} = Atheum.get(row["invocation_id"], c)
    assert pending["status"] == "running"
    assert pending["effect_certainty"] == "unknown"
    assert {:ok, recovered} = Atheum.recover(row["invocation_id"], c)
    assert recovered["result"] == first
    assert recovered["execution_id"] == row["execution_id"]
    assert recovered["attempt_id"] != pending["attempt_id"]
    assert recovered["request"]["apply"] == pending["request"]["apply"]
    assert impact(c, 2) == %{"P" => ["B"]}
    assert {:ok, history} = Atheum.history(row["invocation_id"], c)
    assert Enum.count(history, &(&1["kind"] == "call_intent")) == 2
  end

  test "cancel before execution leaves graph unchanged and no attempt", %{config: c, opts: opts} do
    row = submit(c, opts)
    assert {:ok, cancelled} = Atheum.cancel(row["invocation_id"], c)
    assert cancelled["status"] == "stopped"
    assert cancelled["stop_confirmed"]
    assert cancelled["attempt_id"] == nil
    assert {:error, :not_accepted} = Atheum.run(row["invocation_id"], c)
    assert impact(c, 1) == %{}
  end

  test "cancel after effect preserves completed effect and refuses recovery replay", %{
    config: c,
    opts: opts
  } do
    row = submit(c, opts)

    assert {:ok, done} =
             Atheum.run(row["invocation_id"], c,
               after_effect: fn {:ok, _} ->
                 assert {:ok, cancelled} = Atheum.cancel(row["invocation_id"], c)
                 assert cancelled["status"] == "running"
                 refute cancelled["stop_confirmed"]
               end
             )

    assert done["status"] == "succeeded"
    assert done["cancel_requested"]
    refute done["stop_confirmed"]
    assert impact(c, 2) == %{"P" => ["B"]}
    assert {:error, :not_recoverable} = Atheum.recover(row["invocation_id"], c)
  end

  test "timeout is unknown and exact-payload recovery is safe", %{
    config: c,
    opts: opts,
    root: root
  } do
    # Real CLI commits before the wrapper waits for stdin EOF; no timing sleep or fake DB.
    wrapper = Path.join(root, "delayed-response")

    File.write!(
      wrapper,
      "#!/usr/bin/env python3\nimport subprocess,sys\nr=subprocess.run([" <>
        inspect(c.binary) <>
        "]+sys.argv[1:],capture_output=True)\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(r.stdout)\nsys.exit(r.returncode)\n"
    )

    File.chmod!(wrapper, 0o700)
    row = submit(c, opts)

    assert {:ok, uncertain} =
             Atheum.run(row["invocation_id"], %{c | binary: wrapper, timeout_ms: 1500})

    assert uncertain["status"] == "unresolved"
    assert uncertain["effect_certainty"] == "unknown"
    refute uncertain["stop_confirmed"]
    assert impact(c, 2) == %{"P" => ["B"]}
    assert {:ok, recovered} = Atheum.recover(row["invocation_id"], c)
    assert recovered["result"]["version"] == 2
  end

  test "opt-in and target identity gate actual replay", %{config: c, opts: opts} do
    row = submit(c, Keyword.put(opts, :safe_retry, false))
    assert {:ok, _} = Atheum.run(row["invocation_id"], %{c | binary: "/missing/binary"})
    assert {:error, :retry_disabled} = Atheum.recover(row["invocation_id"], c)

    assert {:error, :target_changed} =
             Atheum.recover(row["invocation_id"], %{c | akashic_identity: "replacement"})

    assert {:ok, _} = Atheum.cancel(row["invocation_id"], c)
    assert {:error, :cancel_requested} = Atheum.recover(row["invocation_id"], c)
    assert impact(c, 1) == %{}
  end

  test "version conflict is a confirmed rejected request", %{config: c, opts: opts} do
    assert {:ok, row} =
             Atheum.submit(
               Postgres.id(),
               %{"supplier_id" => "S1", "active" => false, "expected_version" => 0},
               c,
               opts
             )

    assert {:ok, failed} = Atheum.run(row["invocation_id"], c)
    assert failed["status"] == "failed"
    assert failed["effect_certainty"] == "confirmed_absent"
    assert failed["error"]["code"] == "version_conflict"
    assert impact(c, 1) == %{}
  end

  test "stale worker observation preserves evidence without overwriting recovered state", %{
    config: c,
    opts: opts
  } do
    row = submit(c, opts)
    parent = self()

    worker =
      Task.async(fn ->
        Atheum.run(row["invocation_id"], c,
          after_effect: fn _ ->
            send(parent, :old_effect_done)

            receive do
              :release -> :ok
            end
          end
        )
      end)

    assert_receive :old_effect_done, 15_000
    assert {:ok, recovered} = Atheum.recover(row["invocation_id"], c)
    send(worker.pid, :release)
    assert {:error, :stale_attempt} = Task.await(worker, 15_000)
    assert {:ok, unchanged} = Atheum.get(row["invocation_id"], c)
    assert unchanged == recovered
    assert {:ok, events} = Atheum.history(row["invocation_id"], c)
    assert Enum.any?(events, &(&1["kind"] == "stale_attempt_observed"))
  end

  test "PostgreSQL result write failure after effect is recoverable without graph rollback", %{
    config: c,
    opts: opts
  } do
    row = submit(c, opts)
    trigger = "test_fail_" <> Postgres.id()
    # Trigger belongs to this dedicated test DB and affects exactly one invocation.
    assert {:ok, _} =
             Postgres.query(
               "CREATE FUNCTION #{trigger}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.invocation_id=#{Postgres.text(row["invocation_id"])} AND NEW.kind='attempt_observed' THEN RAISE EXCEPTION 'injected journal write failure'; END IF; RETURN NEW; END $$; CREATE TRIGGER #{trigger} BEFORE INSERT ON atheum_events FOR EACH ROW EXECUTE FUNCTION #{trigger}();",
               c
             )

    try do
      assert {:error, %{"code" => "journal_failure"}} = Atheum.run(row["invocation_id"], c)
      assert impact(c, 2) == %{"P" => ["B"]}
      assert {:ok, pending} = Atheum.get(row["invocation_id"], c)
      assert pending["status"] == "running"
      assert pending["effect_certainty"] == "unknown"
    after
      assert {:ok, _} =
               Postgres.query(
                 "DROP TRIGGER #{trigger} ON atheum_events; DROP FUNCTION #{trigger}();",
                 c
               )
    end

    assert {:ok, recovered} = Atheum.recover(row["invocation_id"], c)
    assert recovered["result"]["version"] == 2
  end

  test "PG target override is blocked and slow actual PG query is bounded", %{config: c} do
    assert {:error, %{"code" => "invalid_configuration"}} =
             Postgres.query("SELECT current_database()", %{
               c
               | pg_url:
                   "postgres://postgres@127.0.0.1:55440/atheum_decoy?dbname=atheum_cycle_test"
             })

    assert {:ok, database} = Postgres.query("SELECT current_database()", c)
    assert database == String.trim_leading(URI.parse(c.pg_url).path, "/")
    start = System.monotonic_time(:millisecond)

    assert {:error, error} =
             Postgres.query("SELECT pg_sleep(0.25)", Map.put(c, :pg_timeout_ms, 75))

    assert error["code"] in ["journal_timeout", "journal_failure"]
    assert System.monotonic_time(:millisecond) - start < 1000
  end

  test "history pages are bounded and invalid paging never reaches PG", %{config: c, opts: opts} do
    row = submit(c, opts)
    assert {:ok, _result} = Atheum.run(row["invocation_id"], c)
    assert {:ok, [first]} = Atheum.history(row["invocation_id"], c, limit: 1)
    assert first["kind"] == "accepted"

    assert {:ok, next} =
             Atheum.history(row["invocation_id"], c, after_sequence: first["sequence"])

    assert Enum.map(next, & &1["kind"]) == ["call_intent", "attempt_observed"]
    assert {:error, :invalid_pagination} = Atheum.history(row["invocation_id"], c, limit: 101)
  end

  test "malformed success after actual effect stays unknown and recovers exact receipt", %{
    config: c,
    opts: opts,
    root: root
  } do
    wrapper = Path.join(root, "bad-success-after-effect")

    File.write!(
      wrapper,
      "#!/usr/bin/env python3\nimport subprocess,sys\nsubprocess.run([" <>
        inspect(c.binary) <>
        "]+sys.argv[1:],stdout=subprocess.DEVNULL,check=True)\nprint('{\"ok\":true,\"result\":{\"apply\":{}}}')\n"
    )

    File.chmod!(wrapper, 0o700)
    row = submit(c, opts)
    assert {:ok, unknown} = Atheum.run(row["invocation_id"], %{c | binary: wrapper})
    assert unknown["status"] == "unresolved"
    assert unknown["effect_certainty"] == "unknown"
    assert unknown["result"] == nil
    refute unknown["stop_confirmed"]
    assert impact(c, 2) == %{"P" => ["B"]}
    assert {:ok, recovered} = Atheum.recover(row["invocation_id"], c)
    assert recovered["result"]["version"] == 2
    assert recovered["request"]["apply"] == row["request"]["apply"]
  end

  test "symmetric contradictory and incomplete envelopes preserve real effect and receipt recovery",
       %{config: c, opts: opts, root: root} do
    variants = [
      {"false_with_success",
       "w['ok']=False; w['error']={'code':'invalid_input','detail':'contradiction'}", 2},
      {"true_with_error", "w['error']={'code':'invalid_input','detail':'contradiction'}", 0},
      {"false_with_null_result",
       "w['ok']=False; w['result']=None; w['error']={'code':'version_conflict','detail':'contradiction'}",
       2},
      {"true_with_null_error", "w['error']=None", 0},
      {"missing_ok", "del w['ok']", 0},
      {"incomplete_rejection", "w={'ok':False,'error':{'code':'invalid_input'}}", 2}
    ]

    Enum.reduce(variants, 1, fn {name, mutation, status}, expected ->
      wrapper = Path.join(root, name)
      wire_path = wrapper <> ".json"

      body =
        "#!/usr/bin/env python3\nimport subprocess,json,sys\nr=subprocess.run([" <>
          inspect(c.binary) <>
          "]+sys.argv[1:],capture_output=True,check=True)\nw=json.loads(r.stdout)\n" <>
          mutation <>
          "\nopen(" <>
          inspect(wire_path) <>
          ",'w').write(json.dumps(w))\nprint(json.dumps(w))\nsys.exit(" <>
          Integer.to_string(status) <> ")\n"

      File.write!(wrapper, body)
      File.chmod!(wrapper, 0o700)

      assert {:ok, row} =
               Atheum.submit(
                 Postgres.id(),
                 %{"supplier_id" => "S1", "active" => false, "expected_version" => expected},
                 c,
                 opts
               )

      assert {:ok, unknown} = Atheum.run(row["invocation_id"], %{c | binary: wrapper})
      assert unknown["status"] == "unresolved"
      assert unknown["effect_certainty"] == "unknown"
      assert unknown["error"]["code"] == "transport_failure"
      refute unknown["stop_confirmed"]
      assert impact(c, expected + 1) == %{"P" => ["B"]}
      assert {:ok, recovered} = Atheum.recover(row["invocation_id"], c)
      assert recovered["status"] == "succeeded"
      assert recovered["result"]["version"] == expected + 1
      assert recovered["request"]["apply"] == row["request"]["apply"]
      assert recovered["execution_id"] == row["execution_id"]
      assert recovered["attempt_id"] != unknown["attempt_id"]
      assert impact(c, expected + 1) == %{"P" => ["B"]}

      IO.puts(
        "ENVELOPE_VARIANT " <>
          JSON.encode!(%{
            "name" => name,
            "wire" => JSON.decode!(File.read!(wire_path)),
            "observed" => unknown["status"],
            "certainty" => unknown["effect_certainty"],
            "recovered_version" => recovered["result"]["version"],
            "same_request" => recovered["request"]["apply"] == row["request"]["apply"]
          })
      )

      assert {:ok, restored} =
               Akashic.apply(
                 %{
                   "command" => "apply",
                   "request" => %{
                     "request_id" => Postgres.id(),
                     "expected_version" => expected + 1,
                     "operations" => [%{"op" => "set_active", "id" => "S1", "active" => true}]
                   }
                 },
                 c
               )

      restored["version"]
    end)
  end
end
