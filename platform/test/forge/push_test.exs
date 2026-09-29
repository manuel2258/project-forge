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

  defp item(kind, ticket, fields \\ %{}) do
    Map.merge(
      %{
        kind: kind,
        ticket: ticket,
        project: Forge.Projects.get!(ticket.project_id),
        since: DateTime.utc_now(),
        question: nil,
        detail: %{}
      },
      fields
    )
  end

  defp question(ticket, key, text),
    do: item(:question, ticket, %{question: %{key: key, text: text}, detail: %{key: key}})

  defp stuck!(ticket) do
    {:ok, ticket} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          cost_usd: ticket.cost_usd
        })
      )

    ticket
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
    ticket = ticket_fixture() |> join_ticket!(user)

    log =
      capture_log(fn ->
        assert :ok = Push.waiting(question(ticket, "backend", "Which backend?"))
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

  describe "what waits" do
    setup %{user: user} do
      {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
      %{ticket: ticket_fixture() |> join_ticket!(user)}
    end

    # Every kind the queue says is waiting pushes, and each links to the work screen on the tab
    # that holds it: Decide for a ticket.
    test "pushes every waiting kind, linked to Decide", %{ticket: ticket} do
      decide = "?tab=decide"

      # Each tagged per thing waiting, so a later push about the same thing replaces this one
      # on the phone and one about another thing does not.
      for {item, title, body, tag} <- [
            {question(ticket, "backend", "Which backend?"), "Question on", "Which backend?",
             "question-#{ticket.id}-backend"},
            {item(:approval, ticket, %{detail: %{"to" => "planning"}}), "Approval on",
             "#{ticket.title} — to planning", "approval-#{ticket.id}"},
            {item(:stuck, ticket), "Stuck:", ticket.title, "stuck-#{ticket.id}"},
            {item(:review, ticket), "Waiting on you:", "#{ticket.title} — in #{ticket.state}",
             "review-#{ticket.id}"}
          ] do
        assert :ok = Push.waiting(item)
        Push.flush()

        assert_receive {:push, "https://push.example/a", payload, _opts}
        assert payload["title"] =~ title
        assert payload["body"] == body
        assert payload["tag"] == tag
        assert payload["url"] == "/tickets/#{item.project.name}/#{ticket.number}" <> decide
      end
    end

    # A conversation's reply is linked to Talk, and tagged per conversation: its next reply
    # replaces this one.
    test "pushes a conversation's reply, linked to Talk", %{ticket: ticket} do
      project = Forge.Projects.get!(ticket.project_id)

      reply = %{
        kind: :chat,
        ticket: nil,
        project: project,
        since: DateTime.utc_now(),
        question: nil,
        detail: %{chat_id: "c-1", text: "Done — the parser is fixed."}
      }

      assert :ok = Push.waiting(reply)
      Push.flush()

      assert_receive {:push, "https://push.example/a", payload, _opts}
      assert payload["title"] == "Reply on #{project.name}"
      assert payload["body"] == "Done — the parser is fixed."
      assert payload["tag"] == "chat-c-1"
      assert payload["url"] == "/chats/c-1?tab=talk"
    end

    # An assumption is in the queue and waits on nobody: the queue's own rule says so, and the
    # push reads that rule rather than a list of its own.
    test "does not push an assumption", %{ticket: ticket} do
      assumption =
        item(:assumption, ticket, %{
          question: %{key: "naming", text: "Which naming?"},
          detail: %{key: "naming"}
        })

      assert :ok = Push.waiting(assumption)
      Push.flush()

      refute_receive {:push, _endpoint, _payload, _opts}
    end
  end

  describe "the watch" do
    setup %{user: user} do
      {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
      %{ticket: ticket_fixture() |> join_ticket!(user)}
    end

    # Once when it starts waiting — not again every time the ticket's row changes while it
    # waits — and again if it stops and starts again.
    test "pushes a ticket once each time it starts waiting", %{ticket: ticket} do
      seen = Push.Watch.changed(%{}, ticket.id)
      Push.flush()
      refute_receive {:push, _endpoint, _payload, _opts}

      stuck!(ticket)
      seen = Push.Watch.changed(seen, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"title" => "Stuck: " <> _}, _opts}

      # Its row moving while it waits — what it has spent, say — is not it starting to wait.
      {:ok, _ticket} =
        Repo.update(
          Ecto.Changeset.change(Forge.Tickets.get!(ticket.id),
            cost_usd: Decimal.new("1.5"),
            updated_at: DateTime.add(DateTime.utc_now(:second), 60)
          )
        )

      seen = Push.Watch.changed(seen, ticket.id)
      Push.flush()
      refute_receive {:push, _endpoint, _payload, _opts}

      {:ok, active} =
        Repo.update(Ecto.Changeset.change(Forge.Tickets.get!(ticket.id), status: :active))

      seen = Push.Watch.changed(seen, active.id)
      stuck!(active)
      _seen = Push.Watch.changed(seen, active.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"title" => "Stuck: " <> _}, _opts}
    end

    # What was waiting when the node started is not news: a restart does not push the queue.
    test "takes what already waits as seen when it starts", %{ticket: ticket} do
      stuck!(ticket)
      start_supervised!(Push.Watch)
      # Read the queue before anything changes: what waits when it starts is seen.
      Push.Watch.sync()

      Forge.Events.notify(ticket.id)
      Push.Watch.sync()
      Push.flush()

      refute_receive {:push, _endpoint, _payload, _opts}
    end

    # A question's key is unique only within its document: two documents asking with the same
    # key are two questions, and each is pushed.
    test "pushes the same key asked by two documents as two questions", %{ticket: ticket} do
      job = job_fixture(%{ticket: ticket})

      ask = fn doc ->
        {:ok, _version} =
          Forge.Artifacts.record_version(ticket.id, doc, :document, {:job, job.id}, %{
            content:
              "---\noutcome: done\n---\n\n```question\nkey: backend\ntext: Which one?\n" <>
                "options: [{label: a, detail: About a}, {label: b, detail: About b}]\nblocking: true\n```\n"
          })
      end

      ask.("refinement.md")
      seen = Push.Watch.changed(%{}, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"title" => "Question on " <> _}, _opts}

      ask.("plan.md")
      _seen = Push.Watch.changed(seen, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"title" => "Question on " <> _}, _opts}
    end

    # A wait is its kind and what it waits at, so the same kind waiting at something else is
    # a new wait: stuck in the next state, another question in the same document, another
    # transition held for approval.
    test "pushes a ticket stuck again in another state", %{ticket: ticket} do
      stuck = stuck!(ticket)
      seen = Push.Watch.changed(%{}, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"title" => "Stuck: " <> _}, _opts}

      {:ok, _ticket} = Repo.update(Ecto.Changeset.change(stuck, state: "planning"))
      _seen = Push.Watch.changed(seen, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"title" => "Stuck: " <> _}, _opts}
    end

    test "pushes a new question in a document it has pushed one from", %{ticket: ticket} do
      job = job_fixture(%{ticket: ticket})

      ask = fn keys ->
        blocks =
          for key <- keys,
              do:
                "```question\nkey: #{key}\ntext: Which #{key}?\noptions: [{label: a, detail: About a}, {label: b, detail: About b}]\n" <>
                  "blocking: true\n```\n"

        {:ok, _version} =
          Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, {:job, job.id}, %{
            content: "---\noutcome: done\n---\n\n" <> Enum.join(blocks, "\n")
          })
      end

      ask.(["backend"])
      seen = Push.Watch.changed(%{}, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"body" => "Which backend?"}, _opts}

      ask.(["backend", "frontend"])
      _seen = Push.Watch.changed(seen, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"body" => "Which frontend?"}, _opts}
      refute_receive {:push, _endpoint, _payload, _opts}
    end

    test "pushes another transition held for approval", %{ticket: ticket} do
      pend = fn to ->
        {:ok, _ticket} =
          Repo.update(
            Ecto.Changeset.change(Forge.Tickets.get!(ticket.id),
              pending_transition: %{
                "from" => "refining",
                "to" => to,
                "outcome" => nil,
                "approve" => ["refinement.md"]
              }
            )
          )
      end

      pend.("planning")
      seen = Push.Watch.changed(%{}, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"title" => "Approval on " <> _}, _opts}

      pend.("done")
      _seen = Push.Watch.changed(seen, ticket.id)
      Push.flush()
      assert_receive {:push, _endpoint, %{"body" => body}, _opts}
      assert body =~ "to done"
    end

    # A ticket that cannot be read leaves what is seen as it was, so the next change looks again,
    # rather than the watch crashing and starting over with everything taken as seen.
    test "leaves what is seen alone when a ticket cannot be read" do
      seen = %{"elsewhere" => MapSet.new([{:stuck, "refining"}])}

      assert capture_log(fn ->
               assert Push.Watch.changed(seen, "not-a-ticket-id") == seen
             end) =~ "could not read ticket"
    end

    # The watch is on the global topic, where a project conversation's changes are announced
    # under no ticket, and it starts on a node whose queue has project conversations in it.
    test "starts beside a waiting project conversation and ignores changes under no ticket" do
      chat = chat_fixture(%{project: project_fixture()})

      :ok =
        Forge.Jobs.record_harness_event(chat.id, %{
          type: "job.harness.text",
          payload: %{text: "Done."}
        })

      {:ok, _chat} =
        Forge.Conversations.record_turn(chat, %{
          "turn" => 1,
          "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
        })

      assert Enum.any?(Forge.Queue.items(), &(&1.kind == :chat and &1.ticket == nil))

      pid = start_supervised!(Push.Watch)
      Push.Watch.sync()

      # Filtered before any work: not a ticket read that fails and says so in the log.
      refute capture_log(fn ->
               Forge.Events.notify(nil)
               Push.Watch.sync()
             end) =~ "push watch"

      assert Process.alive?(pid)
      assert %{seen: %{}} = :sys.get_state(pid)
    end

    test "hears a ticket change and pushes what started waiting", %{ticket: ticket} do
      start_supervised!(Push.Watch)
      # Read the queue before anything changes: what waits when it starts is seen.
      Push.Watch.sync()

      stuck!(ticket)
      Forge.Events.notify(ticket.id)
      Push.Watch.sync()
      Push.flush()

      assert_receive {:push, _endpoint, %{"title" => "Stuck: " <> _}, _opts}
    end
  end

  test "the digest summarises the queue and stays silent when it is empty", %{user: user} do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    assert :empty = Push.digest()
    Push.flush()
    refute_receive {:push, _, _, _}

    ticket = ticket_fixture() |> join_ticket!(user)

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

  test "the digest is sent when one reader has something, even if another has nothing", %{
    user: user
  } do
    # `any?` and not `all?`: two people subscribe, one has a queue and one does not. Answering
    # `:empty` because somebody's queue was empty would silence the person who had work waiting.
    idle = user_fixture()
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/busy"))
    {:ok, _} = Push.subscribe(idle, browser_subscription("https://push.example/idle"))

    ticket = ticket_fixture() |> join_ticket!(user)

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

    assert_receive {:push, "https://push.example/busy", _payload, _opts}
    refute_receive {:push, "https://push.example/idle", _payload, _opts}
  end

  test "a suspended member's device stops receiving", %{user: user} do
    admin = node_admin_fixture()
    ticket = ticket_fixture() |> join_ticket!(user)
    suspended = member_fixture(Forge.Projects.get!(ticket.project_id), :member)

    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/active"))
    {:ok, _} = Push.subscribe(suspended, browser_subscription("https://push.example/suspended"))
    {:ok, _} = Forge.Accounts.suspend_user(suspended, admin)

    assert :ok = Push.waiting(question(ticket, "backend", "Which backend?"))
    Push.flush()

    # Suspension refuses sessions and tokens. A phone that keeps buzzing with questions about a
    # project the account can no longer open is the same access wearing a different hat.
    assert_receive {:push, "https://push.example/active", _payload, _opts}
    refute_receive {:push, "https://push.example/suspended", _payload, _opts}
  end

  test "unsubscribing removes your own device and nobody else's" do
    mine = user_fixture()
    theirs = user_fixture()
    endpoint = "https://push.example/shared-endpoint"

    {:ok, _} = Push.subscribe(mine, browser_subscription(endpoint))
    {:ok, _} = Push.subscribe(theirs, browser_subscription(endpoint))

    :ok = Push.unsubscribe(mine, endpoint)

    # Two people can hold the same endpoint string, and the delete matches on user *and*
    # endpoint. Matching on either would let one person unsubscribe another's phone.
    endpoints = Enum.map(Push.subscriptions(), &{&1.user_id, &1.endpoint})
    refute {mine.id, endpoint} in endpoints
    assert {theirs.id, endpoint} in endpoints
  end

  # The fan-out is a read like any other, and it was the one that reached every device on the
  # node. A blocking question goes to the phones that can answer it: a person who is not in the
  # project cannot open the ticket the notification links to.
  test "a blocking question reaches members only", %{user: user} do
    ticket = ticket_fixture() |> join_ticket!(user)

    # A member of *another* project, not a member of nothing. An outsider with no membership at
    # all is excluded by the join itself, so the project filter could be deleted and this test
    # would still pass — which is exactly what a mutation run found.
    outsider = member_fixture(project_fixture(), :admin)

    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/member"))
    {:ok, _} = Push.subscribe(outsider, browser_subscription("https://push.example/outsider"))

    assert :ok = Push.waiting(question(ticket, "backend", "Which backend?"))
    Push.flush()

    assert_receive {:push, "https://push.example/member", _payload, _opts}
    refute_receive {:push, "https://push.example/outsider", _payload, _opts}
  end

  # A proposal is not a queue item — it blocks nothing — so this is the one place a person is
  # told about one without opening a project page. Without it a proposal nobody looks at is a
  # proposal nobody decides, and the backlog an agent reads keeps offering it back for ever.
  test "the digest counts open proposals, and says they are not waiting on you", %{user: user} do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))

    # The digest counts a reader's own projects, so the proposal has to be in one of them.
    job = job_fixture()
    join!(Forge.Projects.get!(job.project_id), user)
    version = proposal_fixture(%{job: job})

    assert :ok = Push.digest()
    Push.flush()

    # "proposed", not "waiting on you": the queue's promise is that you can reach the end of it,
    # and a proposal was never in it.
    assert_receive {:push, "https://push.example/a",
                    %{"title" => "forge: 1 proposed", "body" => "1 proposed"}, _opts}

    {:ok, _} = Forge.Proposals.decline(version.id, user.id, nil)

    assert :empty = Push.digest()
  end

  # A non-blocking question an agent carried on from: the digest is how it reaches somebody who
  # has not opened its ticket, and it is not waiting on them — so never in "waiting on you".
  defp assume(ticket) do
    {:ok, _version} =
      Forge.Artifacts.record_version(ticket.id, "plan.md", :document, :system, %{
        content: """
        ---
        outcome: done
        ---
        # Plan

        ```question
        key: naming
        text: What is the table called?
        options: [{label: scores, detail: About scores, recommended: true}, {label: highscores, detail: About highscores}]
        blocking: false
        assumption: scores
        ```
        """
      })
  end

  test "the digest counts open assumptions, and says they are not waiting on you", %{
    user: user
  } do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    ticket = ticket_fixture() |> join_ticket!(user)
    assume(ticket)

    assert :ok = Push.digest()
    Push.flush()

    assert_receive {:push, "https://push.example/a",
                    %{"title" => "forge: 1 assumed", "body" => "1 assumed"}, _opts}

    {:ok, _ticket} = Forge.Operator.answer(ticket, user, "naming", %{choice: "highscores"})

    assert :empty = Push.digest()
  end

  test "what is waiting, what was assumed and what is proposed are counted apart", %{user: user} do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))
    ticket = ticket_fixture() |> join_ticket!(user)

    {:ok, _} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          cost_usd: ticket.cost_usd
        })
      )

    assume(ticket)
    proposal_fixture(%{job: job_fixture(%{ticket: ticket})})

    assert :ok = Push.digest()
    Push.flush()

    assert_receive {:push, "https://push.example/a",
                    %{"title" => "forge: 1 waiting on you", "body" => body}, _opts}

    assert body == "1 stuck, 1 assumed, 1 proposed"
  end

  test "a queue item and a proposal are counted separately in one digest", %{user: user} do
    {:ok, _} = Push.subscribe(user, browser_subscription("https://push.example/a"))

    ticket = ticket_fixture() |> join_ticket!(user)

    {:ok, _} =
      Repo.update(
        Forge.Tickets.Ticket.progress_changeset(ticket, %{
          state: ticket.state,
          status: :stuck,
          cost_usd: ticket.cost_usd
        })
      )

    proposal_fixture(%{job: job_fixture(%{ticket: ticket})})

    assert :ok = Push.digest()
    Push.flush()

    assert_receive {:push, "https://push.example/a",
                    %{"title" => "forge: 1 waiting on you", "body" => body}, _opts}

    assert body =~ "1 stuck"
    assert body =~ "1 proposed"
  end
end
