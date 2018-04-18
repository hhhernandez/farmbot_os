defmodule Farmbot.Regimen.Supervisor do
  @moduledoc false
  use Supervisor
  alias Farmbot.Asset
  alias Farmbot.System.ConfigStorage
  alias ConfigStorage.PersistentRegimen
  alias Farmbot.Regimen.NameProvider
  use Farmbot.Logger

  def whats_going_on do
    prs = ConfigStorage.all_persistent_regimens()
    Enum.map(prs, fn(%PersistentRegimen{regimen_id: rid, farm_event_id: fid, time: start_time}) ->
      r = Farmbot.Asset.get_regimen_by_id!(rid, fid)
      server_name = NameProvider.via(r)
      alive = if GenServer.whereis(server_name), do: "is alive", else: "is not alive"
      "Regimen [#{r.name} #{r.id}] started by FarmEvent: [#{fid}] #{Timex.from_now(start_time)} #{alive}"
    end)
  end

  def stop_all_managers(regimen) do
    Logger.info 3, "Stopping all running regimens by id: #{inspect regimen.id}"
    prs = ConfigStorage.persistent_regimens(regimen)
    for %PersistentRegimen{farm_event_id: feid} <- prs do
      reg_with_fe_id = %{regimen | farm_event_id: feid}
      name = NameProvider.via(reg_with_fe_id)
      case GenServer.whereis(name) do
        nil ->
          Logger.info 3, "Could not find regimen by id: #{reg_with_fe_id.id} and tag: #{feid}"

        regimen_server ->
          GenServer.stop(regimen_server)
      end
      ConfigStorage.delete_persistent_regimen(reg_with_fe_id)
    end
  end

  def reindex_all_managers(regimen) do
    Logger.info 3, "Reindexing all running regimens by id: #{regimen.id}"
    prs = ConfigStorage.persistent_regimens(regimen)
    for %{farm_event_id: feid} <- prs do
      reg_with_fe_id = %{regimen | farm_event_id: feid}
      name = NameProvider.via(reg_with_fe_id)
      case GenServer.whereis(name) do
        nil ->
          Logger.info 3, "Could not find regimen by id: #{reg_with_fe_id.id} and tag: #{feid}"
        regimen_server ->
          GenServer.call(regimen_server, {:reindex, reg_with_fe_id})
      end
    end
  end

  @doc false
  def start_link do
    Supervisor.start_link(__MODULE__, [], [name: __MODULE__])
  end

  def init([]) do
    prs = ConfigStorage.all_persistent_regimens()
    children = build_children(prs)
    opts = [strategy: :one_for_one]
    supervise([worker(Farmbot.Regimen.NameProvider, []) | children], opts)
  end

  def add_child(regimen, time) do
    regimen.farm_event_id || raise "Starting a regimen process requires a farm event id tag."
    Logger.debug 3, "Starting regimen: #{regimen.name} #{regimen.farm_event_id} at #{inspect time}"
    ConfigStorage.add_persistent_regimen(regimen, time)
    args = [regimen, time]
    opts = [restart: :transient, id: regimen.farm_event_id]
    spec = worker(Farmbot.Regimen.Manager, args, opts)
    Supervisor.start_child(__MODULE__, spec)
  end

  def stop_child(regimen) do
    regimen.farm_event_id || raise "Stopping a regimen process requires a farm event id tag."
    name = NameProvider.via(regimen)
    case GenServer.whereis(name) do
      nil ->
        Logger.info 3, "Could not find regimen by id: #{regimen.id} and tag: #{regimen.farm_event_id}"

      _regimen_server ->
        Logger.debug 3, "Stopping regimen: #{regimen.name} (#{regimen.farm_event_id})"
        Supervisor.terminate_child(Farmbot.Regimen.Supervisor, regimen.farm_event_id)
        Supervisor.delete_child(Farmbot.Regimen.Supervisor, regimen.farm_event_id)
    end
    ConfigStorage.delete_persistent_regimen(regimen)
  end

  @doc "Builds a list of supervisor children. Will also delete and not build a child from stale data."
  @spec build_children([%PersistentRegimen{}]) :: Supervisor.child_spec()
  def build_children(prs) do
    Enum.reject(prs, fn(%PersistentRegimen{regimen_id: rid, farm_event_id: feid}) ->
      reg = Asset.get_regimen_by_id(rid, feid)
      if Asset.get_farm_event_by_id(feid) && reg do
        _rejected = false
      else
        Logger.debug 3, "Deleting stale persistent regimen: regimen_id: #{rid} farm_event_id: #{feid}"
        # Build a fake regimen to allow the deletion of the persistent regimen
        # if reg above is nil.
        backup = %Farmbot.Asset.Regimen{
          farm_event_id: feid,
          id: rid,
          name: "Not Real", regimen_items: []
        }
        ConfigStorage.delete_persistent_regimen(reg || backup)
        _rejected = true
      end
    end)
    |> Enum.map(fn(%PersistentRegimen{regimen_id: id, time: time, farm_event_id: feid}) ->
      regimen = Asset.get_regimen_by_id!(id, feid)
      args = [regimen, time]
      opts = [restart: :transient, id: feid]
      worker(Farmbot.Regimen.Manager, args, opts)
    end)
  end
end
