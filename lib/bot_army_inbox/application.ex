defmodule BotArmyInbox.Application do
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("[Inbox] Starting bot_army_inbox supervision tree")

    children = [
      BotArmyInbox.Store,
      BotArmyInbox.NATS.Consumer
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 30,
      name: __MODULE__.Supervisor
    )
  end
end
