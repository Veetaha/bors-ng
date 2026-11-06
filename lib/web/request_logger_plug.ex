defmodule BorsNG.RequestLoggerPlug do
  @moduledoc """
  Logs the method, path, status and time of each request, except webhook
  deliveries.

  GitHub sends a webhook for every event of every installed repo. Their
  request lines push all other lines out of a short log buffer. A front
  proxy that logs each request, as on Heroku, still records them.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: Plug.Logger.init(opts)

  @impl Plug
  def call(%Plug.Conn{path_info: ["webhook" | _]} = conn, _level), do: conn
  def call(conn, level), do: Plug.Logger.call(conn, level)
end
