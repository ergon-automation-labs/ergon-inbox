defmodule BotArmyInbox.StoreTest do
  use ExUnit.Case, async: false
  @moduletag :stores

  alias BotArmyInbox.Store

  setup do
    Store.reset()
    :ok
  end

  test "create is idempotent when idempotency_key repeats" do
    payload = %{
      "message_id" => "msg-1",
      "tenant_id" => "tenant-1",
      "user_id" => "user-1",
      "title" => "hello",
      "idempotency_key" => "idem-create-1"
    }

    {:ok, first} = Store.create(payload)
    {:ok, second} = Store.create(payload)

    assert first["message_id"] == "msg-1"
    assert first == second
  end

  test "create auto-generates message_id when missing" do
    payload = %{
      "tenant_id" => "tenant-1",
      "user_id" => "user-1",
      "title" => "hello without id"
    }

    {:ok, created} = Store.create(payload)

    assert is_binary(created["message_id"])
    assert created["message_id"] != ""
    assert String.starts_with?(created["message_id"], "msg-")
  end

  test "a generated message_id does not depend on how long this VM has been up" do
    # This was System.unique_integer/1, which counts from 1 in every VM: the first message after
    # a deploy was `msg-1` again — the same dets key as a message from before the restart, so the
    # older row was silently replaced. The ids below are made by one VM, so what is asserted is
    # what a restart cannot give them: no counter shape, and no repeat across many sends.
    ids =
      for n <- 1..200 do
        {:ok, created} =
          Store.create(%{
            "tenant_id" => "tenant-1",
            "user_id" => "user-1",
            "title" => "message #{n}"
          })

        created["message_id"]
      end

    assert length(Enum.uniq(ids)) == 200
    refute Enum.any?(ids, &Regex.match?(~r/^msg-\d+$/, &1)),
           "a counter-shaped id repeats after a restart: #{Enum.take(ids, 3) |> inspect()}"

    assert Enum.all?(ids, &String.starts_with?(&1, "msg-"))
    assert Enum.all?(ids, &(String.length(&1) >= 16))
  end

  test "create returns idempotency_conflict for same key with different payload" do
    base = %{
      "message_id" => "msg-1x",
      "tenant_id" => "tenant-1",
      "user_id" => "user-1",
      "title" => "hello",
      "idempotency_key" => "idem-create-conflict-1"
    }

    {:ok, _} = Store.create(base)

    changed = Map.put(base, "title", "different title")
    assert {:error, "idempotency_conflict"} = Store.create(changed)
  end

  test "ack is idempotent when idempotency_key repeats" do
    {:ok, _} =
      Store.create(%{
        "message_id" => "msg-2",
        "tenant_id" => "tenant-1",
        "user_id" => "user-1",
        "title" => "needs ack"
      })

    {:ok, first} =
      Store.ack("tenant-1", "user-1", "msg-2", "read", %{"idempotency_key" => "idem-ack-1"})

    {:ok, second} =
      Store.ack("tenant-1", "user-1", "msg-2", "read", %{"idempotency_key" => "idem-ack-1"})

    assert first["status"] == "read"
    assert first == second
  end

  test "ack returns idempotency_conflict for same key with different mutation" do
    {:ok, _} =
      Store.create(%{
        "message_id" => "msg-2x",
        "tenant_id" => "tenant-1",
        "user_id" => "user-1",
        "title" => "needs ack conflict"
      })

    {:ok, _} =
      Store.ack(
        "tenant-1",
        "user-1",
        "msg-2x",
        "read",
        %{"idempotency_key" => "idem-ack-conflict-1"}
      )

    assert {:error, "idempotency_conflict"} =
             Store.ack(
               "tenant-1",
               "user-1",
               "msg-2x",
               "archived",
               %{"idempotency_key" => "idem-ack-conflict-1"}
             )
  end

  test "reply is idempotent when idempotency_key repeats" do
    {:ok, _} =
      Store.create(%{
        "message_id" => "msg-3",
        "tenant_id" => "tenant-1",
        "user_id" => "user-1",
        "title" => "needs reply"
      })

    attrs = %{
      "reply_text" => "roger",
      "reply_to_subject" => "risk.intent.user_reply",
      "correlation_id" => "corr-1"
    }

    {:ok, first} =
      Store.reply(
        "tenant-1",
        "user-1",
        "msg-3",
        attrs,
        %{"idempotency_key" => "idem-reply-1"}
      )

    {:ok, second} =
      Store.reply(
        "tenant-1",
        "user-1",
        "msg-3",
        attrs,
        %{"idempotency_key" => "idem-reply-1"}
      )

    assert length(first["replies"]) == 1
    assert first == second
  end

  test "reply returns idempotency_conflict for same key with different reply text" do
    {:ok, _} =
      Store.create(%{
        "message_id" => "msg-3x",
        "tenant_id" => "tenant-1",
        "user_id" => "user-1",
        "title" => "needs reply conflict"
      })

    attrs_1 = %{
      "reply_text" => "first",
      "reply_to_subject" => "risk.intent.user_reply",
      "correlation_id" => "corr-conflict-1"
    }

    attrs_2 = Map.put(attrs_1, "reply_text", "second")

    {:ok, _} =
      Store.reply(
        "tenant-1",
        "user-1",
        "msg-3x",
        attrs_1,
        %{"idempotency_key" => "idem-reply-conflict-1"}
      )

    assert {:error, "idempotency_conflict"} =
             Store.reply(
               "tenant-1",
               "user-1",
               "msg-3x",
               attrs_2,
               %{"idempotency_key" => "idem-reply-conflict-1"}
             )
  end

  test "a message outlives the process that made it" do
    {:ok, created} =
      Store.create(%{
        "tenant_id" => "tenant-1",
        "user_id" => "user-1",
        "title" => "the roof is leaking",
        "body" => "call the roofer"
      })

    supervisor = BotArmyInbox.Application.Supervisor
    :ok = Supervisor.terminate_child(supervisor, Store)
    {:ok, _pid} = Supervisor.restart_child(supervisor, Store)

    # Nothing carries over in a map: the only way this comes back is the file.
    {:ok, items} = Store.list("tenant-1", "user-1", %{})
    assert [%{"message_id" => id, "status" => "unread"}] = Enum.filter(items, &(&1["message_id"] == created["message_id"]))
    assert id == created["message_id"]

    # An acknowledged message stays acknowledged across the same restart, or the screen would
    # keep offering her the thing she already read.
    {:ok, _} = Store.ack("tenant-1", "user-1", created["message_id"], "read", %{})
    :ok = Supervisor.terminate_child(supervisor, Store)
    {:ok, _pid} = Supervisor.restart_child(supervisor, Store)

    {:ok, after_restart} = Store.list("tenant-1", "user-1", %{})
    assert Enum.find(after_restart, &(&1["message_id"] == created["message_id"]))["status"] == "read"
  end
end
