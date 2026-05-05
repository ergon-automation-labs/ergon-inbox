defmodule BotArmyInbox.Store do
  @moduledoc """
  In-memory inbox state for initial Inbox Bot prototype.
  """

  use GenServer

  @type message :: map()
  @type state :: %{messages: %{String.t() => message()}}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(message), do: GenServer.call(__MODULE__, {:create, message})

  def list(tenant_id, user_id, filters \\ %{}),
    do: GenServer.call(__MODULE__, {:list, tenant_id, user_id, filters})

  def ack(tenant_id, user_id, message_id, new_status),
    do: GenServer.call(__MODULE__, {:ack, tenant_id, user_id, message_id, new_status})

  def count(tenant_id, user_id), do: GenServer.call(__MODULE__, {:count, tenant_id, user_id})

  def reply(tenant_id, user_id, message_id, attrs),
    do: GenServer.call(__MODULE__, {:reply, tenant_id, user_id, message_id, attrs})

  @impl true
  def init(_opts), do: {:ok, %{messages: %{}}}

  @impl true
  def handle_call({:create, message}, _from, state) do
    message_id = message["message_id"] || message["id"]
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    base =
      message
      |> Map.put_new("message_id", message_id)
      |> Map.put_new("status", "unread")
      |> Map.put_new("created_at", now)
      |> Map.put("updated_at", now)

    messages = Map.put(state.messages, message_id, base)
    {:reply, {:ok, base}, %{state | messages: messages}}
  end

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

  def handle_call({:ack, tenant_id, user_id, message_id, new_status}, _from, state) do
    case Map.get(state.messages, message_id) do
      nil ->
        {:reply, {:error, "not_found"}, state}

      msg ->
        if msg["tenant_id"] == tenant_id and msg["user_id"] == user_id do
          now = DateTime.utc_now() |> DateTime.to_iso8601()
          updated = msg |> Map.put("status", new_status) |> Map.put("updated_at", now)
          messages = Map.put(state.messages, message_id, updated)
          {:reply, {:ok, updated}, %{state | messages: messages}}
        else
          {:reply, {:error, "not_found"}, state}
        end
    end
  end

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

  def handle_call({:reply, tenant_id, user_id, message_id, attrs}, _from, state) do
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
          {:reply, {:ok, updated}, %{state | messages: messages}}
        else
          {:reply, {:error, "not_found"}, state}
        end
    end
  end
end
