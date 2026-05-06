# Blocks until the process is terminated (e.g. smoke harness SIGTERM).
# Used instead of `mix run --no-halt` for local smoke subprocesses.

{:ok, _} = Application.ensure_all_started(:bot_army_inbox)
Process.sleep(:infinity)
