defmodule BorsNG.GitHub.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias BorsNG.GitHub.Server

  defmodule StubGitHub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/repositories/1/branches/staging" do
      send_resp(conn, 200, ~s({"commit": {"sha": "old"}}))
    end

    patch "/repositories/1/git/refs/heads/staging" do
      conn
      |> put_resp_header("x-github-request-id", "REQ1")
      |> send_resp(200, "{}")
    end
  end

  setup do
    level = Logger.level()
    Logger.configure(level: :info)
    root = Application.fetch_env!(:bors, :api_github_root)

    on_exit(fn ->
      Logger.configure(level: level)
      Application.put_env(:bors, :api_github_root, root)
    end)
  end

  defp client_with_adapter(adapter) do
    "token t"
    |> Server.tesla_client()
    |> Tesla.Client.middleware()
    |> Tesla.client(adapter)
  end

  test "logs each attempt of a retried write" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    client =
      client_with_adapter(fn env ->
        case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
          1 -> {:error, :closed}
          _ -> {:ok, %{env | status: 200, headers: [{"x-github-request-id", "REQ2"}]}}
        end
      end)

    log =
      capture_log(fn ->
        assert {:ok, %{status: 200}} = Tesla.patch(client, "/repositories/1/git/refs", "{}")
      end)

    assert [[id]] =
             Regex.scan(
               ~r/GitHub request id=(\d+) PATCH .* attempt=1 duration_ms=\d+ error=:closed/,
               log,
               capture: :all_but_first
             )

    assert log =~
             ~r/GitHub request id=#{id} PATCH .*\/repositories\/1\/git\/refs attempt=2 duration_ms=\d+ status=200 github_request_id=REQ2/
  end

  test "logs a GET only when it fails" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    client =
      client_with_adapter(fn env ->
        case Agent.get_and_update(attempts, &{&1 + 1, &1 + 1}) do
          1 -> {:error, :timeout}
          _ -> {:ok, %{env | status: 200}}
        end
      end)

    log = capture_log(fn -> Tesla.get(client, "/repositories/1", query: [page: 2]) end)
    assert log =~ ~r/GET .*\/repositories\/1\?page=2 attempt=1 duration_ms=\d+ error=:timeout/
    refute log =~ "attempt=2"
  end

  test "force_push logs the ref update" do
    ref = make_ref()
    {:ok, _} = Plug.Cowboy.http(StubGitHub, [], port: 0, ref: ref)
    on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    Application.put_env(:bors, :api_github_root, "http://127.0.0.1:#{:ranch.get_port(ref)}")

    log =
      capture_log(fn ->
        assert {:ok, "new"} =
                 Server.do_handle_call(:force_push, {{:raw, "t"}, 1}, {"new", "staging"})
      end)

    assert log =~
             "GitHub ref force update: repo=1 branch=staging before=old sha=new status=200 github_request_id=REQ1"

    assert log =~
             ~r/GitHub request id=\d+ PATCH .* attempt=1 duration_ms=\d+ status=200 github_request_id=REQ1/
  end
end
