defmodule Forge.PushTest do
  use Forge.DataCase, async: false

  import ExUnit.CaptureLog
  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.Push
  alias Forge.Push.TestSender

  setup do
    TestSender.watch()
    %{user: user_fixture()}
  end

  defp key(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp browser_subscription(endpoint, keys \\ %{}) do
    %{
      "endpoint" => endpoint,
      "keys" => Map.merge(%{"p256dh" => key(65), "auth" => key(16)}, keys)
    }
  end

  test "is enabled in test through the configured keys" do
    assert Push.enabled?()
    assert Push.public_key() == "test-public"
  end

  test "subscribe stores or replaces by endpoint; unsubscribe removes", %{user: user} do
    assert {:ok, s1} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    assert {:ok, s2} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    assert s1.id == s2.id
    assert [%{p256dh: p256dh}] = Push.subscriptions()
    assert p256dh == s2.p256dh
    refute p256dh == s1.p256dh

    assert :ok = Push.unsubscribe(user, "https://push.example/a")
    assert Push.subscriptions() == []
  end

  test "subscribe rejects what would crash the push encryption", %{user: user} do
    assert {:error, changeset} = Push.subscribe(user, browser_subscription("http://insecure"))
    assert %{endpoint: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Push.subscribe(
               user,
               browser_subscription("https://push.example/a", %{"p256dh" => "p"})
             )

    assert %{p256dh: [_]} = errors_on(changeset)

    assert {:error, changeset} =
             Push.subscribe(
               user,
               browser_subscription("https://push.example/a", %{"auth" => key(15)})
             )

    assert %{auth: [_]} = errors_on(changeset)

    assert {:error, :malformed} = Push.subscribe(user, %{"endpoint" => "https://push.example/a"})
    assert {:error, :malformed} = Push.subscribe(user, %{"nope" => true})
    assert Push.subscriptions() == []
  end

  test "a blocking question is pushed to every subscription; expired ones are dropped", %{
    user: user
  } do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/expired"))
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/broken"))
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/raises"))
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/b"))
    ticket = ticket_fixture()

    log =
      capture_log(fn ->
        assert :ok = Push.blocking_question(ticket, %{key: "backend", text: "Which backend?"})
        Push.flush()
      end)

    assert log =~ "push.example/broken failed"
    assert log =~ "push.example/raises raised"

    assert_receive {:push, "https://push.example/a",
                    %{"title" => title, "body" => "Which backend?", "url" => url, "tag" => tag},
                    opts}

    assert title =~ "Question on"
    assert url =~ "/tickets/"
    assert tag == "question-#{ticket.id}-backend"
    assert opts[:ttl] == 86_400
    assert opts[:urgency] == :high
    assert String.length(opts[:topic]) == 32

    # the one that raised did not stop the ones after it
    assert_receive {:push, "https://push.example/b", _, _}
    refute_receive {:push, "https://push.example/expired", _, _}

    endpoints = Push.subscriptions() |> Enum.map(& &1.endpoint) |> Enum.sort()

    assert endpoints == [
             "https://push.example/a",
             "https://push.example/b",
             "https://push.example/broken",
             "https://push.example/raises"
           ]

    assert [%{last_sent_at: %DateTime{}}] =
             Enum.filter(Push.subscriptions(), &(&1.endpoint == "https://push.example/a"))

    assert [%{last_sent_at: nil}] =
             Enum.filter(Push.subscriptions(), &(&1.endpoint == "https://push.example/broken"))
  end

  test "the digest summarises the queue and stays silent when it is empty", %{user: user} do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    assert :empty = Push.digest()
    Push.flush()
    refute_receive {:push, _, _, _}

    ticket = ticket_fixture()

    {:ok, _} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          cost_usd: ticket.cost_usd
        })
      )

    assert :ok = Push.digest()
    Push.flush()

    assert_receive {:push, "https://push.example/a",
                    %{"title" => "forge: 1 waiting on you", "body" => "1 stuck", "url" => "/"},
                    opts}

    assert opts[:topic] == "digest"
    assert opts[:ttl] == 43_200
  end

  # A proposal is not a queue item — it blocks nothing — so this is the one place a person is
  # told about one without opening a project page. Without it a proposal nobody looks at is a
  # proposal nobody decides, and the backlog an agent reads keeps offering it back for ever.
  test "the digest counts open proposals, and says they are not waiting on you", %{user: user} do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))

    version = proposal_fixture()

    assert :ok = Push.digest()
    Push.flush()

    # "proposed", not "waiting on you": the queue's promise is that you can reach the end of it,
    # and a proposal was never in it.
    assert_receive {:push, "https://push.example/a",
                    %{"title" => "forge: 1 proposed", "body" => "1 proposed"}, _opts}

    {:ok, _} = Forge.Proposals.decline(version.id, user.id, nil)

    assert :empty = Push.digest()
  end

  test "a queue item and a proposal are counted separately in one digest", %{user: user} do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))

    ticket = ticket_fixture()

    {:ok, _} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          cost_usd: ticket.cost_usd
        })
      )

    proposal_fixture()

    assert :ok = Push.digest()
    Push.flush()

    assert_receive {:push, "https://push.example/a",
                    %{"title" => "forge: 1 waiting on you", "body" => body}, _opts}

    assert body =~ "1 stuck"
    assert body =~ "1 proposed"
  end
end
