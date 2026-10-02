defmodule FinalSensitivityTest do
  use ExUnit.Case
  alias Atheum.{Core,Wire,Postgres}
  test "unknown is preserved" do
    for code <- ["timeout","output_limit","transport_failure"] do
      assert {"unresolved","unknown",nil,_}=Core.completion({:error,%{"code"=>code}})
    end
  end
  test "bad successful result is refused" do
    assert {:error,%{"code"=>"transport_failure"}}=Wire.response(%{"ok"=>true,"result"=>%{"apply"=>%{}}},0,%{"command"=>"apply","request"=>%{"expected_version"=>1}})
  end
  test "query dbname override is refused before adapter" do
    assert {:error,%{"code"=>"invalid_configuration"}}=Postgres.query("SELECT 1",%{psql: "/missing", pg_url: "postgres://postgres@127.0.0.1:55440/atheum_cycle_test?dbname=postgres"})
  end
end
