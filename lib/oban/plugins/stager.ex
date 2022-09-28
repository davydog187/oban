defmodule Oban.Plugins.Stager do
  @moduledoc """
  Makes scheduled jobs available for execution and notifies the relevant queues.

  The Stager transitions jobs from `:scheduled` or `:retryable` to the `:available` state on or
  after the timestamp specified in `:scheduled_at`. It is necessary for the execution of scheduled
  and retryable jobs. As such, it's started by each Oban instance automatically unless `plugins:
  false` is specified.

  It also alerts queues when they have available jobs to trigger execution. Normally, it notifies
  via PubSub in a `:global` mode to minimize database load. When PubSub isn't available the Stager
  falls back to `:local` mode and each queue polls independently.

  Running in `:local` mode typically happens because Postgres is running behind a connection
  pooler that prevents `LISTEN/NOTIFY` commands. To restore global mode, ensure
  `Oban.Notifiers.Postgres` notifications work or switch to `Oban.Notifiers.PG`.

  ## Options

  * `:interval` - the number of milliseconds between database updates. This is directly tied to
    the resolution of _scheduled_ jobs. For example, with an `interval` of `5_000ms`, scheduled
    jobs are checked every 5 seconds. The default is `1_000ms`.

  * `:limit` — the number of jobs that will be staged each time the plugin runs. Defaults to
    `5,000`, which you can increase if staging can't keep up with your insertion rate or decrease
    if you're experiencing staging timeouts.

  ## Instrumenting with Telemetry

  The `Oban.Plugins.Stager` plugin adds the following metadata to the `[:oban, :plugin, :stop]` event:

  * `:staged_count` - the number of jobs that were staged in the database
  """

  @behaviour Oban.Plugin

  use GenServer

  import Ecto.Query,
    only: [
      distinct: 2,
      join: 5,
      limit: 2,
      lock: 2,
      order_by: 2,
      select: 3,
      where: 3
    ]

  alias Oban.{Job, Notifier, Peer, Plugin, Repo, Validation}

  require Logger

  @type option :: Plugin.option() | {:interval, pos_integer()}

  defmodule State do
    @moduledoc false

    defstruct [
      :conf,
      :name,
      :timer,
      interval: :timer.seconds(1),
      limit: 5_000,
      mode: :global,
      ping_at_tick: 0,
      swap_at_tick: 5,
      tick: 0
    ]
  end

  @impl Plugin
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl Plugin
  def validate(opts) do
    Validation.validate(opts, fn
      {:conf, _} -> :ok
      {:name, _} -> :ok
      {:interval, interval} -> Validation.validate_integer(:interval, interval)
      {:limit, limit} -> Validation.validate_integer(:limit, limit)
      option -> {:error, "unknown option provided: #{inspect(option)}"}
    end)
  end

  @impl GenServer
  def init(opts) do
    Validation.validate!(opts, &validate/1)

    Process.flag(:trap_exit, true)

    state = struct!(State, opts)

    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: state.conf, plugin: __MODULE__})

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %State{} = state) do
    Notifier.listen(state.conf.name, :stager)

    state =
      state
      |> schedule_staging()
      |> check_notify_mode()

    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %State{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    :ok
  end

  @impl GenServer
  def handle_info(:stage, %State{} = state) do
    meta = %{conf: state.conf, plugin: __MODULE__}

    :telemetry.span([:oban, :plugin], meta, fn ->
      case check_leadership_and_stage(state) do
        {:ok, staged_count} when is_integer(staged_count) ->
          {:ok, Map.put(meta, :staged_count, staged_count)}

        error ->
          {:error, Map.put(meta, :error, error)}
      end
    end)

    state =
      state
      |> schedule_staging()
      |> check_notify_mode()

    {:noreply, state}
  end

  def handle_info({:notification, :stager, _payload}, %State{} = state) do
    {:noreply, %{state | ping_at_tick: 60, mode: :global, swap_at_tick: 65, tick: 0}}
  end

  defp check_leadership_and_stage(state) do
    leader? = Peer.leader?(state.conf)

    Repo.transaction(state.conf, fn ->
      sched_count = stage_scheduled(state, leader?: leader?)

      notify_queues(state, leader?: leader?)

      sched_count
    end)
  end

  defp stage_scheduled(state, leader?: true) do
    subquery =
      Job
      |> where([j], j.state in ["scheduled", "retryable"])
      |> where([j], not is_nil(j.queue))
      |> where([j], j.scheduled_at <= ^DateTime.utc_now())
      |> order_by(asc: :id)
      |> limit(^state.limit)
      |> lock("FOR UPDATE SKIP LOCKED")

    {count, nil} =
      Repo.update_all(
        state.conf,
        join(Job, :inner, [j], x in subquery(subquery), on: j.id == x.id),
        set: [state: "available"]
      )

    count
  end

  defp stage_scheduled(_state, _leader), do: 0

  defp notify_queues(%State{conf: conf, mode: :global}, leader?: true) do
    query =
      Job
      |> where([j], j.state == "available")
      |> where([j], not is_nil(j.queue))
      |> select([j], %{queue: j.queue})
      |> distinct(true)

    payload = Repo.all(conf, query)

    Notifier.notify(conf, :insert, payload)
  end

  defp notify_queues(%State{conf: conf, mode: :local}, _leader) do
    match = [{{{conf.name, {:producer, :"$1"}}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}]

    for {queue, pid} <- Registry.select(Oban.Registry, match) do
      send(pid, {:notification, :insert, %{"queue" => queue}})
    end
  end

  defp notify_queues(_state, _leader), do: :ok

  # Scheduling

  defp schedule_staging(state) do
    timer = Process.send_after(self(), :stage, state.interval)

    %{state | timer: timer}
  end

  defp check_notify_mode(state) do
    if state.tick >= state.ping_at_tick do
      Notifier.notify(state.conf.name, :stager, %{ping: :pong})
    end

    if state.tick == state.swap_at_tick do
      Logger.warn("""
      Oban job staging switched to local mode.

      Local mode places more load on the database because each queue polls for jobs every second.
      To restore global mode, ensure PostgreSQL notifications work or switch to the PG notifier.
      """)

      %{state | mode: :local}
    else
      %{state | tick: state.tick + 1}
    end
  end
end
