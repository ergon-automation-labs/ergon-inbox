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
end
