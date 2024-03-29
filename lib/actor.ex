defmodule Actor do
  def pid(uuid) do
    case :pg.get_local_members(PGActorUUID, uuid) do
      [] -> nil
      [pid] -> pid
    end
  end

  def pid_by_name(name) do
    case :pg.get_local_members(PGActorName, name) do
      [] -> nil
      [pid] -> pid
    end
  end

  def start(uuid) do
    if MnesiaKV.get(Actor, uuid) do
      MnesiaKV.merge(Actor, uuid, %{enabled: true})
    end
  end

  def stop(uuid) do
    if MnesiaKV.get(Actor, uuid) do
      MnesiaKV.merge(Actor, uuid, %{enabled: false})
    end
  end

  def kill(uuid) do
    pid = pid(uuid)
    pid && Process.exit(pid, :kill)
  end

  def delete(uuid) do
    MnesiaKV.delete(Actor, uuid)
  end

  defmacro __using__(_) do
    quote do
      @after_verify __MODULE__
      def __after_verify__(module) do
        :pg.get_local_members(PGActorAll, module)
        |> Enum.each(& send(&1, :code_update))
        :ok
      end

      def new(params \\ %{}) do
        uuid = params[:uuid] || MnesiaKV.uuid()
        args = %{mod: __MODULE__, uuid: uuid}
        args = if !params[:name], do: args, else: Map.put(args, :name, params.name)

        args =
          if !params[:tick_interval],
            do: Map.put(args, :tick_interval, 1000),
            else: Map.put(args, :tick_interval, params.tick_interval)

        args = if !params[:state], do: args, else: Map.merge(args, params.state)
        MnesiaKV.merge(Actor, args.uuid, args)
        args.uuid
      end

      def unique(params \\ %{}) do
        pattern = Map.merge(%{mod: __MODULE__}, params)

        case MnesiaKV.match_object(Actor, {:_, pattern}) do
          [] -> new(params)
          _ -> nil
        end
      end

      def message(_message, state) do
        state
      end

      def tick(state) do
        state
      end

      def init(state, parent) do
        Process.put(:actor_supervisor, parent)
        pid = self()
        :pg.join(PGActorUUID, state.uuid, pid)
        :pg.join(PGActorUUID, {state.mod, state.uuid}, pid)
        :pg.join(PGActorAll, state.mod, pid)
        :pg.join(PGActorAll, pid)

        if state[:name] do
          :pg.join(PGActorName, state.name, pid)
        end

        :proc_lib.init_ack({:ok, pid})
        loop(state)
      end

      def loop(old_state) do
        state = loop_flush_messages(old_state)

        new_state =
          if state[:enabled] != false do
            tick(state)
          else
            state
          end

        if old_state != new_state do
          MnesiaKV.merge(Actor, new_state.uuid, new_state, [Process.get(:actor_supervisor)])
        end

        __MODULE__.loop(new_state)
      end

      def loop_flush_messages(state) do
        tick_interval = Map.get(state, :tick_interval, 1000)

        receive do
          :code_update ->
            __MODULE__.loop_flush_messages(state)

          {ActorMsg, :update, new_state} ->
            state = MnesiaKV.merge_nested(state, new_state)
            __MODULE__.loop_flush_messages(state)
          {ActorMsg, :update_supervisor, pid} ->
            Process.put(:actor_supervisor, pid)
            __MODULE__.loop_flush_messages(state)

          msg ->
            __MODULE__.loop_flush_messages(message(msg, state))
        after
          tick_interval ->
            state
        end
      end

      defp call_next_rpc_id() do
        rpc_counter = Process.get(:actor_rpc_counter)

        if rpc_counter do
          :atomics.add_get(rpc_counter, 1, 1)
        else
          rpc_counter = :atomics.new(1, [])
          Process.put(:actor_rpc_counter, rpc_counter)
          :atomics.add_get(rpc_counter, 1, 1)
        end
      end

      def call(uuid_or_module, params, timeout \\ 8_000) do
        pid =
          if is_binary(uuid_or_module) do
            case :pg.get_local_members(PGActorUUID, uuid_or_module) do
              [pid] -> pid
              [] -> %{error: :pid_dead}
              [_ | _] -> %{error: :pid_has_many}
            end
          else
            case :pg.get_local_members(PGActorName, uuid_or_module) do
              [pid] -> pid
              [] -> %{error: :pid_dead}
              [_ | _] -> %{error: :pid_has_many}
            end
          end

        if !is_pid(pid) do
          pid
        else
          next_rpc_id = call_next_rpc_id()
          send(pid, {{self(), next_rpc_id}, params})

          receive do
            {Reply, ^next_rpc_id, result} -> result
          after
            timeout ->
              %{error: :timeout}
          end
        end
      end

      def all() do
        MnesiaKV.match_object_index(Actor, %{mod: __MODULE__})
      end

      def start_all() do
        all_actors = all()
        Enum.each(all_actors, &Actor.start(&1))
      end

      def stop_all() do
        all_actors = all()
        Enum.each(all_actors, &Actor.stop(&1))
      end

      def delete_all() do
        all_actors = all()
        Enum.each(all_actors, &Actor.delete(&1))
      end

      defp log(state, line) do
        time = String.slice("#{NaiveDateTime.utc_now()}", 0..-4)
        mod = "#{__MODULE__}" |> String.trim("Elixir.")
        IO.puts("#{time} #{mod} | #{line}")
      end

      defp log(line) do
        time = String.slice("#{NaiveDateTime.utc_now()}", 0..-4)
        IO.puts("#{time} | #{line}")
      end

      # defoverridable new: 1
      defoverridable message: 2
      defoverridable tick: 1
      defoverridable log: 2
    end
  end
end

defmodule ActorSupervisor do
  def start_link(args) do
    pid = :erlang.spawn_opt(__MODULE__, :init, [args], [:link, {:min_heap_size, 256}])
    :erlang.register(__MODULE__, pid)
    {:ok, pid}
  end

  def init(args) do
    IO.inspect("Starting #{__MODULE__}..")
    Process.sleep(100)
    MnesiaKV.subscribe(Actor)
    uuid_pid_ets = :ets.new(:uuid_pid, [:set])
    spawn_queue_ets = :ets.new(:spawn_queue, [:ordered_set])

    Enum.each(MnesiaKV.keys(Actor), fn uuid ->
      case Actor.pid(uuid) do
        nil -> :ets.insert(spawn_queue_ets, {{0, uuid}})
        pid ->
          send(pid, {ActorMsg, :update_supervisor, self()})
          monitor_actor(uuid_pid_ets, uuid, pid)
      end
    end)
    
    app_name = args[:app_name] || get_app_name()

    loop(%{uuid_pid_ets: uuid_pid_ets, spawn_queue_ets: spawn_queue_ets, 
      log_console: args[:log_console] || true, log_file: args[:log_file] || true,
      app_name: app_name
    })
  end

  defp monitor_actor(uuid_pid_ets, uuid, pid) do
    _ref = :erlang.monitor(:process, pid)
    :ets.insert(uuid_pid_ets, {uuid, pid})
    :ets.insert(uuid_pid_ets, {pid, uuid})
  end

  defp get_pid(ets, uuid) do
    try do
      :ets.lookup_element(ets, uuid, 2)
    catch
      :error, :badarg -> nil
    end
  end

  defp get_uuid(ets, pid) do
    try do
      :ets.lookup_element(ets, pid, 2)
    catch
      :error, :badarg -> nil
    end
  end

  defp flush_messages(state) do
    receive do
      {:DOWN, _ref, :process, pid, {{:nocatch, :erase}, _}} ->
        uuid = get_uuid(state.uuid_pid_ets, pid)
        Actor.delete(uuid)

        time = String.slice("#{NaiveDateTime.utc_now()}", 0..-4)
        msg = "#{time} actor deleted #{uuid}\n"
           
        state.log_console && IO.binwrite(msg)
        state.log_file && case File.write("/tmp/#{state.app_name}/error_actor_unhandled", msg, [:append]) do
          :ok -> :ok
          {:error, :enoent} -> File.mkdir_p!("/tmp/#{state.app_name}/"); File.write!("/tmp/#{state.app_name}/error_actor_unhandled", msg, [:append])
        end

        flush_messages(state)

      {:DOWN, _ref, :process, pid, reason} ->
        if reason != :normal do
          time = String.slice("#{NaiveDateTime.utc_now()}", 0..-4)
          msg = "#{time} #{inspect(reason, pretty: true, limit: 9_999_999)}\n"
          
          state.log_console && IO.binwrite(msg)
          state.log_file && case File.write("/tmp/#{state.app_name}/error_actor_unhandled", msg, [:append]) do
            :ok -> :ok
            {:error, :enoent} -> File.mkdir_p!("/tmp/#{state.app_name}/"); File.write!("/tmp/#{state.app_name}/error_actor_unhandled", msg, [:append])
          end
        end

        uuid = get_uuid(state.uuid_pid_ets, pid)

        if uuid do
          :ets.insert(state.spawn_queue_ets, {{:os.system_time(1000) + 5_000, uuid}})
        end

        flush_messages(state)

      {:mnesia_kv_event, :new, Actor, uuid, _map} ->
        :ets.insert(state.spawn_queue_ets, {{0, uuid}})
        flush_messages(state)

      {:mnesia_kv_event, :new, Actor, uuid, _map, _map} ->
        :ets.insert(state.spawn_queue_ets, {{0, uuid}})
        flush_messages(state)

      {:mnesia_kv_event, :merge, Actor, uuid, map, _diff} ->
        pid = get_pid(state.uuid_pid_ets, uuid)
        if pid, do: send(pid, {ActorMsg, :update, map})
        flush_messages(state)

      {:mnesia_kv_event, :delete, Actor, uuid, _deleted_value} ->
        proc_delete(state, uuid)
        flush_messages(state)

      # ignore the rest
      ignored ->
        IO.puts("ex_actors: warning, ignoring message #{inspect(ignored)}")
        flush_messages(state)
    after
      0 ->
        :done
    end
  end

  defp proc_delete(state, uuid) do
    :ets.match_delete(state.spawn_queue_ets, {:_, uuid})

    pid = get_pid(state.uuid_pid_ets, uuid)
    :ets.delete(state.uuid_pid_ets, uuid)

    if pid do
      :ets.delete(state.uuid_pid_ets, pid)
      Process.exit(pid, :kill)
    end
  end

  defp flush_spawn_queue(state) do
    ts_m = :os.system_time(1000)

    case :ets.first(state.spawn_queue_ets) do
      :"$end_of_table" ->
        :done

      {ms, _} when ts_m < ms ->
        :done

      key = {_, uuid} ->
        case spawn_actor(uuid) do
          nil ->
            nil

          pid ->
            :ets.delete(state.spawn_queue_ets, key)
            :ets.insert(state.uuid_pid_ets, {uuid, pid})
            :ets.insert(state.uuid_pid_ets, {pid, uuid})
            flush_spawn_queue(state)
        end
    end
  end

  def spawn_actor(uuid) do
    case Actor.pid(uuid) do
      pid when is_pid(pid) ->
        nil

      nil ->
        state = MnesiaKV.get(Actor, uuid)
        {{:ok, pid}, _ref} = :proc_lib.start_monitor(state.mod, :init, [state, self()])
        pid
    end
  end

  def loop(state) do
    flush_messages(state)
    flush_spawn_queue(state)
    Process.sleep(200)
    __MODULE__.loop(state)
  end

  def get_app_name do
    app_name = :persistent_term.get({Actor, :app_name}, nil)

    if app_name do
      app_name
    else
      line = "mix.exs" |> File.stream!() |> Enum.take(1)
      [name | _] = Regex.run(~r/(\S+)(?=\.)/, to_string(line))
      app_name = String.downcase(name)
      :persistent_term.put({Actor, :app_name}, app_name)
      app_name
    end
  end

  def start(dynamic_supervisor, args \\ %{}) do
    {:ok, _} =
      DynamicSupervisor.start_child(dynamic_supervisor, %{
        id: PGActorAll,
        start: {:pg, :start_link, [PGActorAll]}
      })

    {:ok, _} =
      DynamicSupervisor.start_child(dynamic_supervisor, %{
        id: PGActorUUID,
        start: {:pg, :start_link, [PGActorUUID]}
      })

    {:ok, _} =
      DynamicSupervisor.start_child(dynamic_supervisor, %{
        id: PGActorName,
        start: {:pg, :start_link, [PGActorName]}
      })

    {:ok, _} =
      DynamicSupervisor.start_child(dynamic_supervisor, %{
        id: ActorSupervisor,
        start: {ActorSupervisor, :start_link, [args]}
      })
  end
end
