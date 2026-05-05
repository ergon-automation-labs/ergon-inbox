defmodule BotArmyInbox.NATS.Subjects do
  @moduledoc false

  def inbox_message_create, do: "inbox.message.create"
  def inbox_message_list, do: "inbox.message.list"
  def inbox_message_ack, do: "inbox.message.ack"
  def inbox_message_count, do: "inbox.message.count"
  def inbox_message_reply, do: "inbox.message.reply"

  def bridge_inbox_list, do: "bridge.inbox.list"
  def bridge_inbox_ack, do: "bridge.inbox.ack"
  def bridge_inbox_count, do: "bridge.inbox.count"
  def bridge_inbox_reply, do: "bridge.inbox.reply"
end
