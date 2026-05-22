defmodule BotArmyInbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :bot_army_inbox,
      version: "0.1.3",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BotArmyInbox.Application, []}
    ]
  end

  defp deps do
    [
      {:bot_army_library_core, path: "../bot_army_library_core"},
      {:bot_army_library_runtime, path: "../bot_army_library_runtime"},
      {:jason, "~> 1.4"}
    ]
  end
end
