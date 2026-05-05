defmodule BotArmyInbox.NATS.Consumer do
  @moduledoc """
  NATS request/reply API for Inbox Bot prototype.
  """

  use GenServer
  require Logger
  alias BotArmyInbox.NATS.Subjects
  alias BotArmyInbox.Store

  @subjects [
    Subjects.inbox_message_create(),
    Subjects.inbox_message_list(),
    Subjects.inbox_message_ack(),
    Subjects.inbox_message_count(),
    Subjects.inbox_message_reply()
  ]

  @retry_connect_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Logger.info("[Inbox.NATS] Consumer booting; waiting for NATS connection")
    {:ok, %{conn: nil, subscriptions: []}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        case subscribe_all(conn) do
          {:ok, subscriptions} ->
            Logger.info("[Inbox.NATS] Subscribed to #{length(subscriptions)} inbox subjects")
            {:noreply, %{state | conn: conn, subscriptions: subscriptions}}

          {:error, reason} ->
            Logger.warning(
              "[Inbox.NATS] Failed to subscribe all subjects: #{inspect(reason)}. Retrying in #{@retry_connect_ms}ms"
            )

            Process.send_after(self(), :retry_connect, @retry_connect_ms)
            {:noreply, %{state | conn: nil, subscriptions: []}}
        end

      other ->
        Logger.warning(
          "[Inbox.NATS] NATS connection unavailable: #{inspect(other)}. Retrying in #{@retry_connect_ms}ms"
        )

        Process.send_after(self(), :retry_connect, @retry_connect_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:retry_connect, state), do: {:noreply, state, {:continue, :connect}}

  @impl true
  def handle_info({:msg, msg}, state) do
    payload = decode(msg.body)
    response = handle_request(msg.topic, payload)

    if state.conn && msg.reply_to do
      Gnat.pub(state.conn, msg.reply_to, Jason.encode!(response))
    end

    {:noreply, state}
  end

  defp subscribe_all(conn) do
    Enum.reduce_while(@subjects, {:ok, []}, fn subject, {:ok, acc} ->
      case Gnat.sub(conn, self(), subject) do
        {:ok, sub} ->
          {:cont, {:ok, [sub | acc]}}

        {:error, reason} ->
          {:halt, {:error, {subject, reason}}}
      end
    end)
    |> case do
      {:ok, subs} -> {:ok, Enum.reverse(subs)}
      error -> error
    end
  end

  defp handle_request(topic, payload) do
    case topic do
      "inbox.message.create" ->
        case Store.create(payload) do
          {:ok, item} -> ok(%{"message_id" => item["message_id"], "status" => item["status"]})
          {:error, reason} -> err(reason)
        end

      "inbox.message.list" ->
        tenant_id = payload["tenant_id"]
        user_id = payload["user_id"]

        case Store.list(tenant_id, user_id, payload) do
          {:ok, items} -> ok(%{"messages" => items})
          {:error, reason} -> err(reason)
        end

      "inbox.message.ack" ->
        case Store.ack(
               payload["tenant_id"],
               payload["user_id"],
               payload["message_id"],
               payload["new_status"]
             ) do
          {:ok, item} -> ok(%{"message_id" => item["message_id"], "status" => item["status"]})
          {:error, reason} -> err(reason)
        end

      "inbox.message.count" ->
        case Store.count(payload["tenant_id"], payload["user_id"]) do
          {:ok, counts} ->
            ok(%{
              "unread_total" => counts.unread_total,
              "by_category" => counts.by_category
            })

          {:error, reason} ->
            err(reason)
        end

      "inbox.message.reply" ->
        attrs = %{
          "reply_text" => payload["reply_text"],
          "reply_to_subject" => payload["reply_to_subject"],
          "correlation_id" => payload["correlation_id"]
        }

        case Store.reply(payload["tenant_id"], payload["user_id"], payload["message_id"], attrs) do
          {:ok, item} ->
            ok(%{
              "message_id" => item["message_id"],
              "accepted" => true,
              "routed_subject" =>
                payload["reply_to_subject"] || item["source_subject"] || "inbox.reply.unrouted",
              "correlation_id" => payload["correlation_id"]
            })

          {:error, reason} ->
            err(reason)
        end

      _ ->
        err("unsupported_subject")
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, v} -> v
      _ -> %{}
    end
  end

  defp ok(data) do
    %{
      "ok" => true,
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "data" => data
    }
  end

  defp err(reason) do
    %{
      "ok" => false,
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "error" => to_string(reason)
    }
  end
end
