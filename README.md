# Bot Army Inbox

Inbox Bot system of record for user mailbox state.

## Prototype scope

This first slice provides in-memory request/reply handlers for:

- `inbox.message.create`
- `inbox.message.list`
- `inbox.message.ack`
- `inbox.message.count`
- `inbox.message.reply`
- `bridge.inbox.list`
- `bridge.inbox.ack`
- `bridge.inbox.count`
- `bridge.inbox.reply`

## Run

```bash
cd bot_army_inbox
mix deps.get
mix compile
iex -S mix
```
