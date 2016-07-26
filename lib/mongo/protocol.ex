defmodule Mongo.Protocol do
  use DBConnection
  use Mongo.Messages
  alias Mongo.Protocol.Utils

  @timeout 5000
  @find_flags ~w(tailable_cursor slave_ok no_cursor_timeout await_data exhaust allow_partial_results)a
  @find_one_flags ~w(slave_ok exhaust partial)a
  @insert_flags ~w(continue_on_error)a
  @update_flags ~w(upsert)a
  @write_concern ~w(w j wtimeout)a

  def connect(opts) do
    {write_concern, opts} = Keyword.split(opts, @write_concern)
    write_concern = Keyword.put_new(write_concern, :w, 1)

    s = %{socket: nil,
          request_id: 0,
          timeout: opts[:timeout] || @timeout,
          database: Keyword.fetch!(opts, :database),
          write_concern: write_concern,
          wire_version: nil}

    connect(opts, s)
  end

  defp connect(opts, s) do
    # TODO: with/else in elixir 1.3
    result =
      with {:ok, s} <- tcp_connect(opts |> define_host, s),
           {:ok, s} <- wire_version(s),
           {:ok, s} <- Mongo.Auth.run(opts, s) do
        :ok = :inet.setopts(s.socket, active: :once)
        Mongo.Monitor.add_conn(self(), opts[:name], s.wire_version)
        {:ok, s}
      end

    case result do
      {:ok, s} ->
        {:ok, s}
      {:is_secondary, next_host, next_port, s} ->
        :gen_tcp.close(s.socket)
        opts = opts
        |> Keyword.put(:hostname, next_host)
        |> Keyword.put(:port, next_port)
        connect(opts, s)
      {:no_master, _hosts, s} ->
        :gen_tcp.close(s.socket)
        :timer.sleep(5000)
        connect(opts, s)
      {:econnrefused, next_host, next_port, s} ->
        opts = opts
        |> Keyword.put(:hostname, next_host)
        |> Keyword.put(:port, next_port)
        connect(opts, s)
      {:disconnect, {:tcp_recv, reason}, _s} ->
        {:error, Mongo.Error.exception(tag: :tcp, action: "recv", reason: reason)}
      {:disconnect, {:tcp_send, reason}, _s} ->
        {:error, Mongo.Error.exception(tag: :tcp, action: "send", reason: reason)}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tcp_connect(opts, s) do
    host      = (opts[:hostname] || "localhost") |> to_char_list
    port      = opts[:port] || 27017
    sock_opts = [:binary, active: false, packet: :raw, send_timeout: s.timeout, nodelay: true]
                ++ (opts[:socket_options] || [])

    case :gen_tcp.connect(host, port, sock_opts, s.timeout) do
      {:ok, socket} ->
        # A suitable :buffer is only set if :recbuf is included in
        # :socket_options.
        {:ok, [sndbuf: sndbuf, recbuf: recbuf, buffer: buffer]} =
          :inet.getopts(socket, [:sndbuf, :recbuf, :buffer])
        buffer = buffer |> max(sndbuf) |> max(recbuf)
        :ok = :inet.setopts(socket, buffer: buffer)

        {:ok, %{s | socket: socket}}
      {:error, :econnrefused} ->
        case next_db_server(opts, host, port) do
          {:ok, next_host, next_port} -> {:econnrefused, next_host, next_port, s} 
          :not_found -> {:error, Mongo.Error.exception(tag: :tcp, action: "connect", reason: :econnrefused)}
        end
      {:error, reason} ->
        {:error, Mongo.Error.exception(tag: :tcp, action: "connect", reason: reason)}
    end
  end

  defp wire_version(s) do
    # wire version
    # https://github.com/mongodb/mongo/blob/master/src/mongo/db/wire_version.h
    case Utils.command(-1, [ismaster: 1], s) do
      {:ok, %{"ok" => 1.0, "ismaster" => true} = reply} ->
        {:ok, %{s | wire_version: reply["maxWireVersion"] || 0}}
      {:ok, %{"ok" => 1.0, "ismaster" => false} = reply} ->
        case reply["primary"] do
          nil ->
            {:no_master, reply["hosts"], s}
          primary ->
            [host, port] = String.split(primary, ":")
            {:is_secondary, String.to_char_list(host), String.to_integer(port), s}
        end
      {:disconnect, _, _} = error ->
        error
    end
  end

  defp define_host(opts) do
    case opts[:hosts] do
      [{host, port} | _] ->
        opts
        |> Keyword.put_new(:hostname, host)
        |> Keyword.put_new(:port, port)
      _ -> opts
    end
  end

  defp next_db_server(opts, host, port) do
    case opts[:hosts] do
      nil -> :not_found
      hosts ->
        [h | t] = hosts
        [{next_host, next_port} | _] = t ++ [h]
        cond do
          String.to_char_list(next_host) == host and next_port == port -> :not_found
          true -> {:ok, next_host, next_port}
        end
    end
  end

  def disconnect(_, s) do
    :gen_tcp.close(s.socket)
  end

  def handle_info({:tcp, data}, s) do
    err = Mongo.Error.exception(message: "unexpected async recv: #{inspect data}")
    {:disconnect, err, s}
  end

  def handle_info({:tcp_closed, _}, s) do
    err = Mongo.Error.exception(tag: :tcp, action: "async recv", reason: :closed)
    {:disconnect, err, s}
  end

  def handle_info({:tcp_error, _, reason}, s) do
    err = Mongo.Error.exception(tag: :tcp, action: "async recv", reason: reason)
    {:disconnect, err, s}
  end

  def checkout(s) do
    :ok = :inet.setopts(s.socket, [active: false])
    {:ok, s}
  end

  def checkin(s) do
    :ok = :inet.setopts(s.socket, [active: :once])
    {:ok, s}
  end

  def handle_execute_close(query, params, opts, s) do
    handle_execute(query, params, opts, s)
  end

  def handle_execute(%Mongo.Query{action: action, extra: extra}, params, opts, s) do
    handle_execute(action, extra, params, opts, s)
  end

  defp handle_execute(:find, coll, [query, select], opts, s) do
    flags      = Keyword.take(opts, @find_flags)
    num_skip   = Keyword.get(opts, :skip, 0)
    num_return = Keyword.get(opts, :batch_size, 0)

    op_query(coll: Utils.namespace(coll, s), query: query, select: select,
             num_skip: num_skip, num_return: num_return, flags: flags(flags))
    |> message_reply(s)
  end

  defp handle_execute(:get_more, {coll, cursor_id}, [], opts, s) do
    num_return = Keyword.get(opts, :batch_size, 0)

    op_get_more(coll: Utils.namespace(coll, s), cursor_id: cursor_id,
                num_return: num_return)
    |> message_reply(s)
  end

  defp handle_execute(:kill_cursors, cursor_ids, [], _opts, s) do
    op = op_kill_cursors(cursor_ids: cursor_ids)
    with :ok <- Utils.send(-10, op, s),
         do: {:ok, :ok, s}
  end

  defp handle_execute(:insert_one, coll, [doc], opts, s) do
    flags  = flags(Keyword.take(opts, @insert_flags))
    op     = op_insert(coll: Utils.namespace(coll, s), docs: [doc], flags: flags)
    message_gle(-11, op, opts, s)
  end

  defp handle_execute(:insert_many, coll, docs, opts, s) do
    flags  = flags(Keyword.take(opts, @insert_flags))
    op     = op_insert(coll: Utils.namespace(coll, s), docs: docs, flags: flags)
    message_gle(-12, op, opts, s)
  end

  defp handle_execute(:delete_one, coll, [query], opts, s) do
    flags = [:single]
    op    = op_delete(coll: Utils.namespace(coll, s), query: query, flags: flags)
    message_gle(-13, op, opts, s)
  end

  defp handle_execute(:delete_many, coll, [query], opts, s) do
    flags = []
    op = op_delete(coll: Utils.namespace(coll, s), query: query, flags: flags)
    message_gle(-14, op, opts, s)
  end

  defp handle_execute(:replace_one, coll, [query, replacement], opts, s) do
    flags  = flags(Keyword.take(opts, @update_flags))
    op     = op_update(coll: Utils.namespace(coll, s), query: query, update: replacement,
                       flags: flags)
    message_gle(-15, op, opts, s)
  end

  defp handle_execute(:update_one, coll, [query, update], opts, s) do
    flags  = flags(Keyword.take(opts, @update_flags))
    op     = op_update(coll: Utils.namespace(coll, s), query: query, update: update,
                       flags: flags)
    message_gle(-16, op, opts, s)
  end

  defp handle_execute(:update_many, coll, [query, update], opts, s) do
    flags  = [:multi | flags(Keyword.take(opts, @update_flags))]
    op     = op_update(coll: Utils.namespace(coll, s), query: query, update: update,
                       flags: flags)
    message_gle(-17, op, opts, s)
  end

  defp handle_execute(:command, nil, [query], opts, s) do
    flags = Keyword.take(opts, @find_one_flags)
    op_query(coll: Utils.namespace("$cmd", s), query: query, select: "",
             num_skip: 0, num_return: 1, flags: flags(flags))
    |> message_reply(s)
  end

  defp message_reply(op, s) do
    with {:ok, reply} <- Utils.message(s.request_id, op, s),
         s = %{s | request_id: s.request_id + 1},
         do: {:ok, reply, s}
  end

  defp flags(flags) do
    Enum.reduce(flags, [], fn
      {flag, true},   acc -> [flag|acc]
      {_flag, false}, acc -> acc
    end)
  end

  defp message_gle(id, op, opts, s) do
    write_concern = Keyword.take(opts, @write_concern)
    write_concern = Dict.merge(s.write_concern, write_concern)

    if write_concern[:w] == 0 do
      with :ok <- Utils.send(id, op, s), do: {:ok, :ok, s}
    else
      command = BSON.Encoder.document([{:getLastError, 1}|write_concern])
      gle_op = op_query(coll: Utils.namespace("$cmd", s), query: command,
                        select: "", num_skip: 0, num_return: -1, flags: [])

      ops = [{id, op}, {s.request_id, gle_op}]
      message_reply(ops, s)
    end
  end

  def ping(%{wire_version: wire_version} = s) do
    :ok = :inet.setopts(s.socket, [active: false])
    with {:ok, %{wire_version: ^wire_version}} <- wire_version(s),
         :ok = :inet.setopts(s.socket, [active: :once]),
         do: {:ok, s}
  end
end
