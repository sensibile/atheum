defmodule Atheum.Postgres do
  @moduledoc "PostgreSQL shell. psql is a local replaceable adapter; each query is a transaction."
  alias Atheum.ProcessIO

  def query(sql, config) do
    with {:ok, connection} <- connection(config.pg_url) do
      execute(sql, config, connection)
    end
  end

  def connection(url) when is_binary(url), do: parse_connection(URI.parse(url))
  def connection(_url), do: invalid_connection()

  defp parse_connection(%URI{
         scheme: scheme,
         host: host,
         port: port,
         path: path,
         userinfo: user,
         query: nil,
         fragment: nil
       })
       when scheme in ["postgres", "postgresql"] and host in ["localhost", "127.0.0.1"] and
              is_integer(port) and port in 1..65_535 and is_binary(path) and is_binary(user) do
    if Regex.match?(~r/\A\/atheum_[a-zA-Z0-9_]{1,55}\z/, path) and
         Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_]*\z/, user) do
      {:ok, %{host: host, port: port, user: user, database: String.trim_leading(path, "/")}}
    else
      invalid_connection()
    end
  end

  defp parse_connection(_uri), do: invalid_connection()

  defp invalid_connection,
    do:
      {:error,
       %{
         "code" => "invalid_configuration",
         "detail" =>
           "explicit localhost atheum_ DB URL; query/fragment/password/escaped components forbidden"
       }}

  defp execute(sql, config, connection) do
    timeout = Map.get(config, :pg_timeout_ms, Map.get(config, :timeout_ms, 5_000))

    if is_integer(timeout) and timeout in 1..60_000 do
      do_execute(sql, config, connection, timeout)
    else
      {:error,
       %{"code" => "invalid_configuration", "detail" => "pg_timeout_ms must be 1..60000ms"}}
    end
  end

  defp do_execute(sql, config, connection, timeout) do
    # libpq cannot reinterpret this bare validated DB name as a connection string.
    args = [
      "-X",
      "-q",
      "-A",
      "-t",
      "-w",
      "-v",
      "ON_ERROR_STOP=1",
      "-h",
      connection.host,
      "-p",
      Integer.to_string(connection.port),
      "-U",
      connection.user,
      "-d",
      connection.database,
      "-c",
      "DO $$ BEGIN IF current_database() <> '#{connection.database}' THEN RAISE EXCEPTION 'target DB mismatch'; END IF; END $$; " <>
        sql
    ]

    env = [
      {"PGHOSTADDR", nil},
      {"PGSERVICE", nil},
      {"PGSERVICEFILE", nil},
      {"PGDATABASE", nil},
      {"PGHOST", nil},
      {"PGPORT", nil},
      {"PGUSER", nil},
      {"PGOPTIONS", "-c statement_timeout=#{timeout} -c lock_timeout=#{timeout}"},
      {"PGCONNECT_TIMEOUT", Integer.to_string(max(div(timeout + 999, 1000), 1))}
    ]

    case ProcessIO.run(config.psql, args, timeout, env) do
      {:ok, output, 0} ->
        {:ok, String.trim(output)}

      {:ok, output, _status} ->
        {:error, %{"code" => "journal_failure", "detail" => String.trim(output)}}

      {:error, error} ->
        {:error, Map.put(error, "code", "journal_" <> error["code"])}
    end
  end

  def value(value),
    do: "convert_from(decode('" <> Base.encode16(JSON.encode!(value)) <> "','hex'),'UTF8')::jsonb"

  def text(value), do: "(" <> value(value) <> " #>> '{}')"

  def setup(config) do
    query(File.read!(Path.expand("../../priv/schema.sql", __DIR__)), config)
  end

  def get(id, config) do
    case query(
           "SELECT row_to_json(i) FROM atheum_invocations i WHERE invocation_id=#{text(id)}",
           config
         ) do
      {:ok, ""} -> {:error, :not_found}
      {:ok, output} -> {:ok, JSON.decode!(output)}
      error -> error
    end
  end

  def history(id, config, opts \\ []) do
    after_sequence = Keyword.get(opts, :after_sequence, 0)
    limit = Keyword.get(opts, :limit, 100)

    if is_integer(after_sequence) and after_sequence >= 0 and is_integer(limit) and
         limit in 1..100 do
      history_page(id, config, after_sequence, limit)
    else
      {:error, :invalid_pagination}
    end
  end

  defp history_page(id, config, after_sequence, limit) do
    case query(
           "SELECT COALESCE(json_agg(e ORDER BY sequence),'[]'::json) FROM (SELECT * FROM atheum_events WHERE invocation_id=#{text(id)} AND sequence>#{after_sequence} ORDER BY sequence LIMIT #{limit}) e",
           config
         ) do
      {:ok, output} -> {:ok, JSON.decode!(output)}
      error -> error
    end
  end

  def submit(key, request, config) do
    invocation = id()
    execution = id()

    sql = """
    WITH inserted AS (
      INSERT INTO atheum_invocations(invocation_id,execution_id,acceptance_key,request,status)
      VALUES(#{text(invocation)},#{text(execution)},#{text(key)},#{value(request)},'accepted')
      ON CONFLICT(acceptance_key) DO NOTHING RETURNING *
    ), logged AS (
      INSERT INTO atheum_events(invocation_id,kind,data)
      SELECT invocation_id,'accepted',request FROM inserted RETURNING invocation_id
    ) SELECT row_to_json(inserted) FROM inserted;
    """

    case query(sql, config) do
      {:ok, ""} ->
        existing_acceptance(key, request, config)

      {:ok, output} ->
        {:ok, JSON.decode!(output)}

      error ->
        error
    end
  end

  defp existing_acceptance(key, request, config) do
    # Separate statement sees a concurrent winner after ON CONFLICT waits.
    with {:ok, output} <-
           query(
             "SELECT row_to_json(i) FROM atheum_invocations i WHERE acceptance_key=#{text(key)}",
             config
           ) do
      row = JSON.decode!(output)

      if row["request"]["fingerprint"] == request["fingerprint"],
        do: {:ok, row},
        else: {:error, :acceptance_conflict}
    end
  end

  def transition(id, condition, assignments, kind, data, config) do
    sql = """
    WITH changed AS (
      UPDATE atheum_invocations SET #{assignments},updated_at=clock_timestamp()
      WHERE invocation_id=#{text(id)} AND (#{condition}) RETURNING *
    ), logged AS (
      INSERT INTO atheum_events(invocation_id,attempt_id,kind,data)
      SELECT invocation_id,attempt_id,#{text(kind)},#{value(data)} FROM changed RETURNING invocation_id
    ) SELECT row_to_json(changed) FROM changed;
    """

    case query(sql, config) do
      {:ok, ""} -> {:error, :transition_conflict}
      {:ok, output} -> {:ok, JSON.decode!(output)}
      error -> error
    end
  end

  def id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
