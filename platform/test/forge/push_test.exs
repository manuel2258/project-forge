defmodule Forge.PushTest do
  use Forge.DataCase, async: false

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures

  alias Forge.Push
  alias Forge.Push.TestSender

  setup do
    TestSender.watch()
    %{user: user_fixture()}
  end

  defp browser_subscription(endpoint) do
    %{"endpoint" => endpoint, "keys" => %{"p256dh" => "p", "auth" => "a"}}
  end

  test "is enabled in test through the configured keys" do
    assert Push.enabled?()
    assert Push.public_key() == "test-public"
  end

  test "subscribe stores or replaces by endpoint; unsubscribe removes", %{user: user} do
    assert {:ok, s1} =
             Push.subscribe(user, browser_subscription("https://push.example/a"), "Firefox")

    assert {:ok, s2} =
             Push.subscribe(user, browser_subscription("https://push.example/a"), "Firefox 2")

    assert s1.id == s2.id
    assert [%{user_agent: "Firefox 2"}] = Push.subscriptions()

    assert {:error, changeset} =
             Push.subscribe(user, browser_subscription("http://insecure"), nil)

    assert %{endpoint: [_]} = errors_on(changeset)

    assert :ok = Push.unsubscribe(user, "https://push.example/a")
    assert Push.subscriptions() == []
  end

  test "a blocking question is pushed to every subscription; expired ones are dropped", %{
    user: user
  } do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/expired"))
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/broken"))
    ticket = ticket_fixture()

    assert :ok = Push.blocking_question(ticket, %{key: "backend", text: "Which backend?"})

    assert_receive {:push, "https://push.example/a",
                    %{"title" => title, "body" => "Which backend?", "url" => url, "tag" => tag}}

    assert title =~ "Question on"
    assert url =~ "/tickets/"
    assert tag == "question-#{ticket.id}-backend"
    refute_receive {:push, "https://push.example/expired", _}

    endpoints = Push.subscriptions() |> Enum.map(& &1.endpoint) |> Enum.sort()
    assert endpoints == ["https://push.example/a", "https://push.example/broken"]

    assert [%{last_sent_at: %DateTime{}} | _] =
             Enum.filter(Push.subscriptions(), &(&1.endpoint == "https://push.example/a"))
  end

  test "the digest summarises the queue and stays silent when it is empty", %{user: user} do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    assert :empty = Push.digest()
    refute_receive {:push, _, _}

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

    assert_receive {:push, "https://push.example/a",
                    %{"title" => "forge: 1 waiting on you", "body" => "1 stuck", "url" => "/"}}
  end
end
