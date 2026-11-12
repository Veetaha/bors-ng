defmodule BorsNG.Worker.Batcher.Registry do
  @moduledoc """
  The "Batcher" manages the backlog of batches that each project has.
  This is the registry of each individual batcher.
  It starts the batcher if it doesn't exist,
  and logs the crashes because that's needed sometimes.

  Note that the batcher and registry are always on the same node.
  Sharding between them will be done by directing which registry to go to.
  """

  use GenServer

  alias BorsNG.Worker.Batcher
  alias BorsNG.Database.Batch
  alias BorsNG.Database.Crash
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo

  require Logger

  @name BorsNG.Worker.Batcher.Registry
  @names BorsNG.Worker.Batcher.Names

  # Public API

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: @name)
  end

  @doc """
  The name of the batcher of the project. A project has at most one batcher.
  """
  def via(project_id), do: {:via, Elixir.Registry, {@names, project_id}}

  def get(project_id) when is_integer(project_id) do
    case GenServer.whereis(via(project_id)) do
      nil -> Batcher.Supervisor.start(project_id)
      pid -> pid
    end
  end

  def monitor(pid, project_id) do
    GenServer.cast(@name, {:monitor, project_id, pid})
  end

  # Server callbacks

  def init(:ok) do
    (Repo.all(Project.active()) ++ Repo.all(Project.with_prerun()))
    |> Enum.map(fn %{id: id} -> id end)
    |> Enum.uniq()
    |> Enum.each(&Batcher.Supervisor.start/1)

    {:ok, Map.new()}
  end

  def handle_cast({:monitor, project_id, pid}, refs) do
    {:noreply, Map.put(refs, Process.monitor(pid), project_id)}
  end

  # `:noproc` is a batcher that exited before the monitor started.
  # Its exit reason is unknown, and its supervisor logs a crash.
  def handle_info({:DOWN, ref, :process, _pid, reason}, refs)
      when reason in [:normal, :noproc] do
    {:noreply, Map.delete(refs, ref)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, refs) do
    {project_id, refs} = Map.pop(refs, ref)

    Logger.warn("Batcher #{inspect(pid)} for project #{project_id} crashed: #{inspect(reason)}")

    project_id
    |> Batch.all_for_project(:waiting)
    |> Repo.all()
    |> Enum.each(&Repo.delete!/1)

    project_id
    |> Batch.all_for_project(:running)
    |> Repo.all()
    |> Enum.map(&Batch.changeset(&1, %{state: :canceled}))
    |> Enum.each(&Repo.update!/1)

    Repo.insert(%Crash{
      project_id: project_id,
      component: "batch",
      crash: inspect(reason, pretty: true, width: 60)
    })

    {:noreply, refs}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
