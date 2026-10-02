defmodule IndependentEnvelopeTest do
  use ExUnit.Case, async: false
  alias Atheum.{Akashic, Core, Postgres, Wire}

  defp result do
    %{
      "version" => 1,
      "changed" => true,
      "difference" =>
        Map.new(["added_products", "removed_products", "newly_blocked", "restored"], &{&1, []}),
      "work" =>
        Map.new(["recomputed_parts", "recomputed_products", "visited_relations"], &{&1, 0})
    }
  end

  test "independent required field, type, exit and duplicate matrix" do
    req = %{"command" => "apply", "request" => %{"expected_version" => 0}}
    good = %{"ok" => true, "result" => %{"apply" => result()}}

    bad = %{
      "ok" => false,
      "error" => %{"code" => "invalid_input", "detail" => "normal rejection"}
    }

    assert {:ok, _} = Wire.response(good, 0, req)
    assert {:error, %{"code" => "invalid_input"}} = Wire.response(bad, 2, req)
    matrix = for base <- [good, bad], exit <- [-1, 0, 1, 2, 127], do: {"exit", base, exit}

    matrix =
      matrix ++
        for base <- [good, bad],
            key <- Map.keys(base),
            do: {"missing_" <> key, Map.delete(base, key), if(base["ok"], do: 0, else: 2)}

    matrix =
      matrix ++
        for key <- Map.keys(result()),
            value <- [nil, "1", -1, [], %{}, false],
            do: {"apply_" <> key, put_in(good, ["result", "apply", key], value), 0}

    for {name, wire, exit} <- matrix do
      actual = Wire.response(wire, exit, req)
      valid = (wire == good and exit == 0) or (wire == bad and exit == 2)

      unless valid do
        assert {:error, %{"code" => "transport_failure"} = e} = actual
        assert {"unresolved", "unknown", nil, ^e} = Core.completion(actual)
      end

      IO.puts(
        "MATRIX " <>
          JSON.encode!(%{"case" => name, "wire" => wire, "exit" => exit, "accepted" => valid})
      )
    end

    for bytes <- [
          ~s({"ok":false,"error":{"code":"invalid_input","detail":"x","detail":"y"}}),
          ~s({"ok":true,"result":{},"\\u006fk":false}),
          ~s({"ok":false,"error":{"code":"invalid_input","detail":"x"}}\nnull)
        ] do
      assert {:error, %{"code" => "transport_failure"}} = Wire.decode(bytes)
    end
  end

  @tag :integration
  test "actual changed effect, independently tampered responses, exact receipt and history" do
    root = Path.join(System.tmp_dir!(), "independent-" <> Postgres.id())
    File.mkdir_p!(root)

    c = %{
      psql: System.find_executable("psql"),
      pg_url: System.fetch_env!("ATHEUM_TEST_PG_URL"),
      binary: System.fetch_env!("AKASHIC_BINARY"),
      akashic_db: Path.join(root, "db"),
      akashic_identity: Postgres.id(),
      storage: :snapshot,
      timeout_ms: 10_000
    }

    assert {:ok, _} = Postgres.setup(c)

    assert {:ok, _} =
             Akashic.apply(
               %{
                 "command" => "apply",
                 "request" => %{
                   "request_id" => "seed",
                   "expected_version" => 0,
                   "operations" => [
                     %{
                       "op" => "add_object",
                       "id" => "S",
                       "object" => %{"kind" => "supplier", "active" => true}
                     }
                   ]
                 }
               },
               c
             )

    variants = [
      {"success_wrong_exit", "print(r.stdout.decode());sys.exit(2)"},
      {"duplicate_ok", "print(r.stdout.decode().replace('{', '{\"ok\":false,',1));sys.exit(2)"},
      {"null_error", "w['error']=None;print(json.dumps(w))"},
      {"false_plus_result",
       "w['ok']=False;w['error']={'code':'invalid_input','detail':'contradiction'};print(json.dumps(w));sys.exit(2)"},
      {"missing_detail",
       "print(json.dumps({'ok':False,'error':{'code':'invalid_input'}}));sys.exit(2)"},
      {"missing_work", "del w['result']['apply']['work'];print(json.dumps(w))"}
    ]

    Enum.with_index(variants, 1)
    |> Enum.each(fn {{name, mutation}, version} ->
      wrapper = Path.join(root, name)

      File.write!(
        wrapper,
        "#!/usr/bin/env python3\nimport subprocess,json,sys\nr=subprocess.run([" <>
          inspect(c.binary) <>
          "]+sys.argv[1:],capture_output=True,check=True)\nw=json.loads(r.stdout)\n" <>
          mutation <> "\n"
      )

      File.chmod!(wrapper, 0o700)

      assert {:ok, row} =
               Atheum.submit(
                 Postgres.id(),
                 %{
                   "supplier_id" => "S",
                   "active" => rem(version, 2) == 0,
                   "expected_version" => version
                 },
                 c,
                 deadline_ms: System.system_time(:millisecond) + 60_000,
                 safe_retry: true
               )

      assert {:ok, unknown} = Atheum.run(row["invocation_id"], %{c | binary: wrapper})
      assert unknown["effect_certainty"] == "unknown"
      assert unknown["status"] == "unresolved"
      refute unknown["stop_confirmed"]
      assert {:ok, done} = Atheum.recover(row["invocation_id"], c)
      assert done["result"]["changed"] == true
      assert done["result"]["version"] == version + 1
      assert done["request"] == row["request"]
      assert done["execution_id"] == row["execution_id"]

      assert {:ok, receipt} =
               Akashic.apply(%{"command" => "apply", "request" => row["request"]["apply"]}, c)

      assert receipt == done["result"]
      assert {:ok, %{"version" => v}} = Akashic.apply(%{"command" => "validate"}, c)
      assert v == version + 1
      assert {:ok, events} = Atheum.history(row["invocation_id"], c)

      assert Enum.map(events, & &1["kind"]) == [
               "accepted",
               "call_intent",
               "attempt_observed",
               "call_intent",
               "attempt_observed"
             ]

      IO.puts(
        "REAL " <>
          JSON.encode!(%{
            "variant" => name,
            "unknown" => unknown,
            "recovered" => done,
            "receipt" => receipt,
            "events" => events
          })
      )
    end)

    File.rm_rf!(root)
  end
end
