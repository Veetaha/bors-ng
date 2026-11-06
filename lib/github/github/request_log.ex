require Logger

defmodule BorsNG.GitHub.RequestLog do
  @moduledoc """
  Tesla middleware that logs each attempt of a GitHub API request.

  Use it twice in the middleware list: with the `:request` option before
  the retry middleware, and with the `:attempt` option after it. The
  `:request` part gives the request an id and an attempt counter. The
  `:attempt` part runs once per attempt. It logs every attempt of a request
  that is not a GET, and every transport error.
  """

  @behaviour Tesla.Middleware

  @impl Tesla.Middleware
  def call(env, next, :request) do
    log = %{id: System.unique_integer([:positive]), attempts: :counters.new(1, [])}
    Tesla.run(Tesla.put_opt(env, :request_log, log), next)
  end

  def call(%{opts: opts} = env, next, :attempt) do
    log = Keyword.fetch!(opts, :request_log)
    :counters.add(log.attempts, 1, 1)
    attempt = :counters.get(log.attempts, 1)
    start = System.monotonic_time()
    result = Tesla.run(env, next)

    case result do
      {:error, reason} ->
        Logger.warning(fn ->
          [prefix(env, log, attempt, start), " error=", inspect(reason)]
        end)

      {:ok, resp} when env.method != :get ->
        Logger.info(fn ->
          [
            prefix(env, log, attempt, start),
            " status=#{resp.status} github_request_id=",
            Tesla.get_header(resp, "x-github-request-id") || ""
          ]
        end)

      {:ok, _} ->
        :ok
    end

    result
  end

  defp prefix(env, log, attempt, start) do
    duration = System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
    method = env.method |> Atom.to_string() |> String.upcase()
    url = Tesla.build_url(env.url, env.query)
    "GitHub request id=#{log.id} #{method} #{url} attempt=#{attempt} duration_ms=#{duration}"
  end
end
