defmodule BotArmyInbox.Store do
  @moduledoc """
  In-memory inbox state for initial Inbox Bot prototype.
  """

  use GenServer

  @type message :: map()
  @type idempotency_entry :: %{fingerprint: binary(), result: map()}
  @type idempotency_cache :: %{String.t() => idempotency_entry}
  @type state :: %{messages: %{String.t() => message()}, idempotency: idempotency_cache}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(message), do: GenServer.call(__MODULE__, {:create, message})

  def list(tenant_id, user_id, filters \\ %{}),
    do: GenServer.call(__MODULE__, {:list, tenant_id, user_id, filters})

  def ack(tenant_id, user_id, message_id, new_status, opts \\ %{}),
    do: GenServer.call(__MODULE__, {:ack, tenant_id, user_id, message_id, new_status, opts})

  def count(tenant_id, user_id), do: GenServer.call(__MODULE__, {:count, tenant_id, user_id})

  def reply(tenant_id, user_id, message_id, attrs, opts \\ %{}),
    do: GenServer.call(__MODULE__, {:reply, tenant_id, user_id, message_id, attrs, opts})

  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, %{messages: %{}, idempotency: %{}}}

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{messages: %{}, idempotency: %{}}}
  end

  @impl true
  def handle_call({:create, message}, _from, state) do
    idempotency_key = message["idempotency_key"]
    tenant_id = message["tenant_id"]
    user_id = message["user_id"]
    op_scope = idempotency_scope("create", tenant_id, user_id, idempotency_key)
    fingerprint = fingerprint_create(message)

    case get_idempotent_result(state, op_scope, fingerprint) do
      {:ok, cached, _state} ->
        {:reply, {:ok, cached}, state}

      {:error, reason, _state} ->
        {:reply, {:error, reason}, state}

      :miss ->
        do_create(message, state, op_scope, fingerprint)
    end
  end

  @impl true
  def handle_call({:list, tenant_id, user_id, filters}, _from, state) do
    status_filter = Map.get(filters, "status")
    category_filter = Map.get(filters, "category")
    limit = Map.get(filters, "limit", 50)

    items =
      state.messages
      |> Map.values()
      |> Enum.filter(fn msg -> msg["tenant_id"] == tenant_id and msg["user_id"] == user_id end)
      |> Enum.filter(fn msg -> is_nil(status_filter) or msg["status"] == status_filter end)
      |> Enum.filter(fn msg -> is_nil(category_filter) or msg["category"] == category_filter end)
      |> Enum.sort_by(&Map.get(&1, "created_at", ""), :desc)
      |> Enum.take(limit)

    {:reply, {:ok, items}, state}
  end

  @impl true
  def handle_call({:ack, tenant_id, user_id, message_id, new_status, opts}, _from, state) do
    idempotency_key = opts["idempotency_key"]
    op_scope = idempotency_scope("ack", tenant_id, user_id, idempotency_key)
    fingerprint = fingerprint_ack(message_id, new_status)

    case get_idempotent_result(state, op_scope, fingerprint) do
      {:ok, cached, _state} ->
        {:reply, {:ok, cached}, state}

      {:error, reason, _state} ->
        {:reply, {:error, reason}, state}

      :miss ->
        do_ack(tenant_id, user_id, message_id, new_status, state, op_scope, fingerprint)
    end
  end

  @impl true
  def handle_call({:count, tenant_id, user_id}, _from, state) do
    items =
      state.messages
      |> Map.values()
      |> Enum.filter(fn msg -> msg["tenant_id"] == tenant_id and msg["user_id"] == user_id end)

    unread_total = Enum.count(items, &(&1["status"] == "unread"))

    by_category =
      items
      |> Enum.filter(&(&1["status"] == "unread"))
      |> Enum.group_by(&Map.get(&1, "category", "other"))
      |> Map.new(fn {k, v} -> {k, Enum.count(v)} end)

    {:reply, {:ok, %{unread_total: unread_total, by_category: by_category}}, state}
  end

  @impl true
  def handle_call({:reply, tenant_id, user_id, message_id, attrs, opts}, _from, state) do
    idempotency_key = opts["idempotency_key"]
    op_scope = idempotency_scope("reply", tenant_id, user_id, idempotency_key)
    fingerprint = fingerprint_reply(message_id, attrs)

    case get_idempotent_result(state, op_scope, fingerprint) do
      {:ok, cached, _state} ->
        {:reply, {:ok, cached}, state}

      {:error, reason, _state} ->
        {:reply, {:error, reason}, state}

      :miss ->
        do_reply(tenant_id, user_id, message_id, attrs, state, op_scope, fingerprint)
    end
  end

  defp do_create(message, state, op_scope, fingerprint) do
    message_id = message["message_id"] || message["id"] || new_message_id()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    base =
      message
      |> Map.put("message_id", message_id)
      |> Map.put_new("status", "unread")
      |> Map.put_new("created_at", now)
      |> Map.put("updated_at", now)

    messages = Map.put(state.messages, message_id, base)
    next_state = put_idempotent_result(%{state | messages: messages}, op_scope, fingerprint, base)
    {:reply, {:ok, base}, next_state}
  end

  defp do_ack(tenant_id, user_id, message_id, new_status, state, op_scope, fingerprint) do
    case Map.get(state.messages, message_id) do
      nil ->
        {:reply, {:error, "not_found"}, state}

      msg ->
        if msg["tenant_id"] == tenant_id and msg["user_id"] == user_id do
          now = DateTime.utc_now() |> DateTime.to_iso8601()
          updated = msg |> Map.put("status", new_status) |> Map.put("updated_at", now)
          messages = Map.put(state.messages, message_id, updated)

          next_state =
            put_idempotent_result(%{state | messages: messages}, op_scope, fingerprint, updated)

          {:reply, {:ok, updated}, next_state}
        else
          {:reply, {:error, "not_found"}, state}
        end
    end
  end

  defp do_reply(tenant_id, user_id, message_id, attrs, state, op_scope, fingerprint) do
    case Map.get(state.messages, message_id) do
      nil ->
        {:reply, {:error, "not_found"}, state}

      msg ->
        if msg["tenant_id"] == tenant_id and msg["user_id"] == user_id do
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          reply_event = %{
            "reply_text" => attrs["reply_text"],
            "reply_to_subject" => attrs["reply_to_subject"],
            "correlation_id" => attrs["correlation_id"],
            "replied_at" => now
          }

          replies = (msg["replies"] || []) ++ [reply_event]

          updated =
            msg
            |> Map.put("replies", replies)
            |> Map.put("updated_at", now)
            |> Map.put("replied_at", now)

          messages = Map.put(state.messages, message_id, updated)

          next_state =
            put_idempotent_result(%{state | messages: messages}, op_scope, fingerprint, updated)

          {:reply, {:ok, updated}, next_state}
        else
          {:reply, {:error, "not_found"}, state}
        end
    end
  end

  defp idempotency_scope(_op, _tenant_id, _user_id, nil), do: nil

  defp idempotency_scope(op, tenant_id, user_id, key) do
    "#{op}|#{tenant_id}|#{user_id}|#{key}"
  end

  defp get_idempotent_result(_state, nil, _fingerprint), do: :miss

  defp get_idempotent_result(state, scope, fingerprint) do
    case Map.get(state.idempotency, scope) do
      nil ->
        :miss

      %{fingerprint: ^fingerprint, result: result} ->
        {:ok, result, state}

      %{fingerprint: _other} ->
        {:error, "idempotency_conflict", state}
    end
  end

  defp put_idempotent_result(state, nil, _fingerprint, _value), do: state

  defp put_idempotent_result(state, scope, fingerprint, value) do
    entry = %{fingerprint: fingerprint, result: value}
    %{state | idempotency: Map.put(state.idempotency, scope, entry)}
  end

  defp fingerprint_create(message) when is_map(message) do
    message
    |> Map.drop(["idempotency_key"])
    |> :erlang.term_to_binary()
  end

  defp fingerprint_ack(message_id, new_status) do
    :erlang.term_to_binary({message_id, new_status})
  end

  defp fingerprint_reply(message_id, attrs) when is_map(attrs) do
    attrs_for_fingerprint =
      attrs
      |> Map.take(["reply_text", "reply_to_subject", "correlation_id"])

    :erlang.term_to_binary({message_id, attrs_for_fingerprint})
  end

  defp new_message_id do
    "msg-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
