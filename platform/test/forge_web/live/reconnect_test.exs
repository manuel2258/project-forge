defmodule ForgeWeb.ReconnectTest do
  @moduledoc """
  A socket that drops while the page sits idle must not take what was typed with it
  (`docs/design/ui.md` § A reconnect is not a reload).

  **What a test here reaches, and what it cannot.** The recovery is the client's: on a rejoin
  LiveView copies every `form[phx-change]` that has an `id` out of the live DOM and re-pushes
  that form's change event with what was typed, before it applies the new mount's render
  (`deps/phoenix_live_view/assets/js/phoenix_live_view/view.ts`, `maybeRecoverForms`). No ExUnit
  test can drive a browser, so the contract is pinned in the two halves that both have to hold:

  - the **shape**, which decides whether the client replays anything at all — the box is in a
    form carrying an `id` and a `phx-change`;
  - the **handler**, which decides whether the replay is worth anything — the page holds what
    the replayed change carried, and draws the box from it.

  `render_change/3` on a form is exactly the event the client replays, so the second half is
  driven for real. The first is asserted on the markup, because the markup is what the client
  reads to decide whether to replay.
  """

  use ForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Forge.GitFixtures

  alias Forge.{Conversations, Jobs, Projects, Tickets}
  alias ForgeWeb.Operator.Drafts

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, project} =
      Projects.register(
        %{name: "rc-#{System.unique_integer([:positive])}", repo_path: seeded_repo()},
        user
      )

    data_dir = tmp_dir("data")
    original = Application.get_env(:forge, Forge.Jobs)
    Application.put_env(:forge, Forge.Jobs, Keyword.put(original, :data_dir, data_dir))

    store = Application.get_env(:forge, Forge.Storage, [])
    Application.put_env(:forge, Forge.Storage, Keyword.put(store, :dir, tmp_dir("store")))

    on_exit(fn ->
      Application.put_env(:forge, Forge.Jobs, original)
      Application.put_env(:forge, Forge.Storage, store)
    end)

    Process.put(:worker, Forge.FakeWorker.connect())
    %{project: project}
  end

  defp run_pending(ticket_id, scenario, doc) do
    [job] = Enum.filter(Jobs.for_ticket(ticket_id), &(&1.status == :pending))
    {:ok, job} = Forge.FakeWorker.run(job, Process.get(:worker), scenario, doc: doc)
    job
  end

  defp awaiting_approval(project, user) do
    {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
    run_pending(ticket.id, "success", "refinement.md")
    ticket
  end

  # Every box a person types into, and the form the client would have to replay to put it back.
  # A textarea outside any form is counted too, because the client cannot replay one at all.
  defp boxes(html) do
    doc = Floki.parse_document!(html)
    in_forms = for form <- Floki.find(doc, "form"), box <- typed_into(form), do: {form, box}

    loose = length(typed_into(doc)) - length(in_forms)
    {in_forms, loose}
  end

  # The same boxes `holds_a_box?/2` counts below, so the walk and the inventory cannot disagree
  # about what a person types into: an `<.input type="number">` drawn outside a form would
  # otherwise pass the walk and fail the inventory.
  defp typed_into(node),
    do:
      Floki.find(
        node,
        "textarea, input[type=text], input[type=email], input[type=password], " <>
          "input[type=url], input[type=number]"
      )

  # The shape half: if this fails, nothing the handler does matters, because the client never
  # sends the event that would reach it.
  defp assert_recoverable(html, where) do
    {in_forms, loose} = boxes(html)

    assert loose == 0, "#{where}: #{loose} box(es) in no form at all, which nothing can replay"
    assert in_forms != [], "#{where}: no box to check — the surface did not draw what it should"

    for {form, box} <- in_forms do
      name = Floki.attribute(box, "name")

      assert Floki.attribute(form, "id") != [],
             "#{where}: the form holding #{inspect(name)} has no id, so it is never replayed"

      assert Floki.attribute(form, "phx-change") != [],
             "#{where}: the form holding #{inspect(name)} has no phx-change, so it is never " <>
               "copied for replay"
    end
  end

  describe "the shape a rejoin needs" do
    test "holds on the queue, with an approval and a question waiting", %{
      conn: conn,
      user: user,
      project: project
    } do
      awaiting_approval(project, user)

      {:ok, asking} = Tickets.admit(project, %{title: "Ask me"}, {:user, user.id})
      run_pending(asking.id, "blocking", "refinement.md")

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Approving pins"
      assert_recoverable(html, "the queue")
    end

    test "holds on a ticket's Decide", %{conn: conn, user: user, project: project} do
      ticket = awaiting_approval(project, user)

      {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide")
      assert html =~ "Approving pins"
      assert_recoverable(html, "a ticket's Decide")
    end

    # The ticket's own two surfaces, both drawn by `ForgeWeb.Operator.QuestionForm`: a question
    # waiting on a document is answered on the page that holds the document, not from the queue,
    # which links to it (`docs/design/ui.md` § Answering questions).
    test "holds on a ticket's Decide with a question open", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Ask me"}, {:user, user.id})
      run_pending(ticket.id, "blocking", "refinement.md")

      {:ok, _view, html} = live(conn, ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide")
      assert html =~ "Which backend?"
      assert_recoverable(html, "a ticket's question")
    end

    test "holds on a project's proposals", %{conn: conn, user: user, project: project} do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
      [job | _] = Jobs.for_ticket(ticket.id)

      Forge.ForgeFixtures.proposal_fixture(%{
        job: job,
        title: "Extract the score table",
        body: "The plan assumes a module that is not there."
      })

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.name}")
      assert html =~ "Extract the score table"
      assert_recoverable(html, "a project's proposals")
    end
  end

  describe "the handler a rejoin's replay lands in" do
    # This is the event the client re-pushes on a rejoin, against a view that has just mounted
    # and holds nothing — which is the whole of what a rejoin is on the server's side.
    test "puts an approval's comment back", %{conn: conn, user: user, project: project} do
      ticket = awaiting_approval(project, user)
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> form("#approve-#{ticket.id}", %{"comment" => "pinned at the wrong one"})
      |> render_change()

      assert view |> element("#approval-#{ticket.id} textarea[name=comment]") |> render() =~
               "pinned at the wrong one"
    end

    # The three `render_component` tests below hand `drafts` in ready-made, so the path from a
    # replayed payload to a drawn `<select>` was covered nowhere: adding `ticket_type` to the
    # keys `Drafts.handle/3` throws away left every test green. This drives the handler itself
    # and draws the component from what it held.
    test "puts back every field of a replayed form, the chosen type included" do
      assert {:state, socket} =
               Drafts.handle(
                 "draft:change",
                 %{
                   "draft" => "propose-v1",
                   "version_id" => "v1",
                   "comment" => "worth doing after the release",
                   "ticket_type" => "bug"
                 },
                 %Phoenix.LiveView.Socket{}
               )

      html = proposal_html(socket.assigns.drafts)
      assert html =~ "worth doing after the release"
      assert selected(html) == ["bug"]
    end

    test "puts a proposal's comment and its chosen type back", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, ticket} = Tickets.admit(project, %{title: "Persist scores"}, {:user, user.id})
      [job | _] = Jobs.for_ticket(ticket.id)

      version =
        Forge.ForgeFixtures.proposal_fixture(%{
          job: job,
          title: "Extract the score table",
          body: "The plan assumes a module that is not there."
        })

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.name}")

      view
      |> form("#propose-#{version.id}", %{"comment" => "worth doing after the release"})
      |> render_change()

      assert view |> element("#proposal-comment-#{version.id}") |> render() =~
               "worth doing after the release"
    end
  end

  # The two surfaces the ticket named — a reply being typed, and a question being answered
  # (`answers.md`, `loss-surface`). Both are on the conversation page, and both are drawn from
  # state the rejoin's `mount/3` does not have: `@draft` for the composer, `@forms` for the
  # question. The fresh `live/2` below is the rejoin — `mount/3` cannot tell one from a reload —
  # and the change pushed against it is the one the client replays.
  describe "a conversation's reply" do
    setup %{project: project} do
      {:ok, chat} = Conversations.open(project, "what is this repository?")
      %{chat: chat}
    end

    defp asked(chat) do
      :ok =
        Jobs.record_harness_event(chat.id, %{
          type: "job.harness.text",
          payload: %{
            text: """
            One thing.

            ```question
            key: backend
            text: Which backend should it use?
            options:
              - {label: postgres, detail: About postgres, recommended: true}
              - {label: sqlite, detail: About sqlite}
            ```
            """
          }
        })

      {:ok, _chat} =
        Conversations.record_turn(chat, %{
          "turn" => 1,
          "harness" => %{"turns" => 1, "cost_usd" => 0.01, "subtype" => "success"}
        })
    end

    test "holds the shape, with a question docked under the composer", %{conn: conn, chat: chat} do
      asked(chat)

      {:ok, _view, html} = live(conn, ~p"/chats/#{chat.id}")
      assert html =~ "Which backend should it use?"
      assert_recoverable(html, "a conversation")
    end

    test "puts the composer's draft back", %{conn: conn, chat: chat} do
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      view |> element("#say") |> render_change(%{"text" => "half of a sentence"})

      assert view |> element("#draft") |> render() =~ "half of a sentence"
    end

    test "puts an open question's answer back", %{conn: conn, chat: chat} do
      asked(chat)
      {:ok, view, _html} = live(conn, ~p"/chats/#{chat.id}")

      # The recommendation is what the box is drawn on until somebody chooses, so a test that
      # only looked at the choice would pass on a form that had lost the answer and fallen back.
      assert checked(view) == ["postgres"]

      view
      |> element("#answer-rows form")
      |> render_change(%{
        "answers" => %{"backend" => %{"choice" => "sqlite", "text" => "a note"}}
      })

      assert checked(view) == ["sqlite"]
      assert view |> element("#answer-rows form") |> render() =~ "a note"
    end

    defp checked(view) do
      view
      |> element("#answer-rows form")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find(~s(input[type=radio][checked]))
      |> Floki.attribute("value")
    end
  end

  # The select beside a proposal's comment, which a rejoin has to put back too — drawn straight,
  # because the pages that offer it are the ones whose project has types.
  describe "a proposal's chosen type" do
    defp proposal_html(drafts) do
      render_component(&ForgeWeb.Operator.Components.proposals/1,
        proposals: [
          %{
            title: "Extract the score table",
            file: "proposal-score-table.md",
            body: "It is a day's work.",
            version_id: "v1",
            project: "game",
            ticket_number: 7,
            readable: true,
            suggested: "chore"
          }
        ],
        types: [%{name: "bug", parses: true}, %{name: "chore", parses: true}],
        drafts: drafts
      )
    end

    defp selected(html) do
      html
      |> Floki.parse_fragment!()
      |> Floki.find("select[name=ticket_type] option[selected]")
      |> Floki.attribute("value")
    end

    test "is the suggestion until somebody chooses" do
      assert selected(proposal_html(%{})) == ["chore"]
    end

    test "is what a replayed change carried, over the suggestion" do
      assert selected(proposal_html(%{"propose-v1" => %{"ticket_type" => "bug"}})) == ["bug"]
    end

    # Choosing *Choose a type* is a choice. Falling back to the suggestion here would put a type
    # back that the person had deliberately taken off.
    test "is nothing when the replayed change carried nothing chosen" do
      assert selected(proposal_html(%{"propose-v1" => %{"ticket_type" => ""}})) == []
    end
  end

  describe "a human state's document" do
    setup %{user: user} do
      workflow =
        Path.expand("../../../../core/test/fixtures/workflow_example.yml", __DIR__)
        |> File.read!()
        |> String.replace(
          "  review_ready: {}",
          "  review_ready:\n    produces: [test-report.md]"
        )

      {:ok, project} =
        Projects.register(
          %{
            name: "rcd-#{System.unique_integer([:positive])}",
            repo_path: seeded_repo(%{".forge/workflow.yml" => workflow})
          },
          user
        )

      {:ok, ticket} = Tickets.admit(project, %{title: "Try it"}, {:user, user.id})

      {:ok, ticket} =
        ticket |> Ecto.Changeset.change(state: "review_ready") |> Forge.Repo.update()

      %{project: project, ticket: ticket}
    end

    test "is in a form a rejoin can replay, and comes back when it does", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      path = ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide"
      {:ok, view, html} = live(conn, path)
      assert html =~ "test-report.md"
      assert_recoverable(html, "a human state's document")

      view
      |> form(~s(form[id="write-test-report.md"]), %{"content" => "half of a sentence"})
      |> render_change()

      assert view |> element(~s([id="write-test-report.md"])) |> render() =~
               "half of a sentence"
    end

    # The draft outlives the socket, not the send. Left behind, it would be drawn over the
    # version that was just written — and over every later one.
    test "stops holding the draft once it is saved", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      path = ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide"
      {:ok, view, _html} = live(conn, path)

      view
      |> form(~s(form[id="write-test-report.md"]), %{"content" => "half of a sentence"})
      |> render_change()

      view
      |> form(~s(form[id="write-test-report.md"]), %{"content" => "the whole thing\n"})
      |> render_submit()

      assert %{version: 1, content: "the whole thing\n"} =
               Forge.Artifacts.latest(ticket.id, "test-report.md")

      editor = view |> element(~s([id="write-test-report.md"])) |> render()
      assert editor =~ "the whole thing"
      refute editor =~ "half of a sentence"
    end

    # The other half of the same line: `ForgeWeb.Operator.Actions.act_on/3` forgets a draft on
    # success and deliberately not on a refusal, so a send that was turned down leaves what was
    # typed to send again. Only a comment defended that, and forgetting on both branches passed
    # the whole suite — a refused save or a refused approval losing the text is this ticket's own
    # defect, on the surface this ticket added.
    #
    # The document editor is where the rule is observable and the approval card is not: the
    # refusal easiest to arrange there — somebody else decided it first — takes the pending
    # transition away, so the card the comment sits in is not drawn at all afterwards. One
    # `act_on` serves both.
    test "keeps the draft when the save is refused", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      path = ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide"
      {:ok, view, _html} = live(conn, path)

      # An unclosed question block: `ForgeCore.Document.parse/1` refuses it, so nothing is
      # written and there is no saved version for the box to fall back to.
      refused = "```question\nkey: a\n"
      editor = ~s(form[id="write-test-report.md"])

      # The change the client debounces out while it is typed, then the Save it was typed for.
      view |> form(editor, %{"content" => refused}) |> render_change()
      html = view |> form(editor, %{"content" => refused}) |> render_submit()

      assert html =~ "Failed:"
      assert Forge.Artifacts.latest(ticket.id, "test-report.md") == nil
      assert view |> element(~s([id="write-test-report.md"])) |> render() =~ "key: a"
    end

    # The draft outliving the socket is what this ticket is for; outliving a version somebody
    # else wrote while it sat there is not. Before the draft was held, the box was redrawn from
    # `@latest` on every reload, so a Save could only ever land on what the operator had just
    # been shown. Now the box keeps the draft — so the Save has to say which version the text was
    # written against, and be refused when that is not the latest any more
    # (`docs/design/ui.md` § A reconnect is not a reload). Both people's work is still on screen
    # afterwards: theirs in the document, the operator's in the box.
    test "refuses to save a draft that a newer version has overtaken", %{
      conn: conn,
      project: project,
      user: user,
      ticket: ticket
    } do
      {:ok, _ticket} = Forge.Operator.edit(ticket, user, "test-report.md", "mine, v1\n")

      path = ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide"
      {:ok, view, _html} = live(conn, path)
      editor = ~s(form[id="write-test-report.md"])

      view |> form(editor, %{"content" => "typed against v1\n"}) |> render_change()

      # Somebody else writes while the draft sits in the box. The page reloads on the event and
      # keeps the draft, which is the point — and makes the Save below a stale write.
      {:ok, _ticket} = Forge.Operator.edit(ticket, user, "test-report.md", "theirs, v2\n")

      html = view |> form(editor, %{"content" => "typed against v1\n"}) |> render_submit()

      assert html =~ "is at v2 now"

      assert %{version: 2, content: "theirs, v2\n"} =
               Forge.Artifacts.latest(ticket.id, "test-report.md")

      assert view |> element(~s([id="write-test-report.md"])) |> render() =~ "typed against v1"
    end

    # `Drafts.forget/2` is handed `params["draft"]`, and six events on this page carry no such
    # param: Repin, Retry, Integrate, Cancel, Restore and a hand-taken transition are all
    # `phx-click` buttons. A `forget/2` that cleared the map instead of nothing would wipe a
    # half-typed document on any of them, and nothing said so but the docstring.
    test "a button that names no draft keeps one that is held", %{
      conn: conn,
      project: project,
      ticket: ticket
    } do
      path = ~p"/tickets/#{project.name}/#{ticket.number}?tab=decide"
      {:ok, view, _html} = live(conn, path)

      view
      |> form(~s(form[id="write-test-report.md"]), %{"content" => "half of a sentence"})
      |> render_change()

      # Repin only succeeds when the default branch has moved, so move it.
      commit_to_default(project, %{"README.md" => "moved on\n"})
      html = render_click(view, "repin", %{"ticket" => ticket.id})

      assert html =~ "Re-pinned at"
      assert view |> element(~s([id="write-test-report.md"])) |> render() =~ "half of a sentence"
    end
  end

  # Every form in the web layer that holds a box a person types into, and whether a rejoin can
  # put what was typed back. The page walks above cover the five surfaces this ticket is about;
  # this covers the ones nobody walks, a page that does not exist yet included — a new form with
  # a box and no replay fails here until somebody records it. Same shape as
  # `authorization_inventory_test.exs`: a claim in a note with a way to fail.
  #
  # A form's box is often not written in the form: `message_box/1` draws the operator's,
  # `open_question/1` the question form's, `model_field/1` and `template_fields/1` the settings
  # ones. The first version of this scan read only a form's own body and so saw none of them —
  # which is how a seventh form lost what was typed while the note said six. It now asks which
  # components draw a box, to a fixpoint, and counts a call to one of those.
  #
  # What it still does not reach is a box drawn outside a form altogether. No page draws one
  # today; if one appears, only the walks above would catch it, and only on the pages they visit.
  describe "every form that holds a box" do
    # The forms that still lose what was typed, and why none is fixed here: giving back a
    # secret's value or a password means holding it in page state, which is a decision for a
    # person (`docs/design/secrets.md`), and the other two are that same decision about a page
    # holding what was typed into it.
    @unrecoverable %{
      {"live/project_settings_live.ex", "add-member"} => "an email, on a project's members",
      {"live/project_settings_live.ex", "set-secret"} => "a secret's name and its value",
      {"live/project_settings_live.ex", "add-mirror"} => "a mirror's url, user and token",
      {"live/workers_live.ex", "save"} => "a worker's memory and cores",
      {"live/project_settings_live.ex", "model"} => "a model name, while no worker is connected",
      {"live/user_live/login.ex", "submit_magic"} => "an email, to be sent a link",
      {"live/user_live/login.ex", "submit_password"} => "an email and a password"
    }

    test "either recovers on a rejoin, or is recorded as not" do
      {recovers, loses} = Enum.split_with(forms_with_boxes(), &elem(&1, 1))
      keys = Enum.map(loses, &elem(&1, 0))
      recorded = MapSet.new(Map.keys(@unrecoverable))

      assert keys == Enum.uniq(keys),
             "two forms in one file under one name, so one hides the other: #{inspect(keys)}"

      unrecorded = MapSet.difference(MapSet.new(keys), recorded)

      assert MapSet.to_list(unrecorded) == [],
             "form(s) holding a box that a rejoin cannot replay, with nothing recording why: " <>
               inspect(MapSet.to_list(unrecorded))

      stale = MapSet.difference(recorded, MapSet.new(keys))

      assert MapSet.to_list(stale) == [],
             "recorded as losing what was typed, but it does not any more — drop the entry: " <>
               inspect(MapSet.to_list(stale))

      # The surfaces this ticket is about, by name. A scan that stopped seeing one of them would
      # pass everything above, and the first version of this one did exactly that: `message_box`
      # is a component, so none of the forms holding the operator's own unsent work matched a
      # `<textarea>`.
      recovering = Enum.map(recovers, &elem(&1, 0))

      for site <- [
            {"live/chat_live.ex", "send"},
            {"live/operator/components.ex", "decide"},
            {"live/operator/components.ex", "decide_proposal"},
            {"live/operator/components.ex", "write_document"}
          ] do
        assert site in recovering, "#{inspect(site)} is not in the scan at all"
      end
    end

    # One entry per form that holds a box: `{{file, the event it submits}, whether a rejoin can
    # replay it}`. A rejoin replays a form carrying both an `id` and a `phx-change`, and nothing
    # else (this file's moduledoc).
    defp forms_with_boxes do
      sources = Map.new(Path.wildcard("lib/forge_web/**/*.{ex,heex}"), &{&1, File.read!(&1)})
      drawn = box_components(sources)

      Enum.flat_map(sources, fn {path, source} ->
        file = Path.relative_to(path, "lib/forge_web")

        for {tag, body} <- forms(markup(path, source)), holds_a_box?(body, drawn) do
          {{file, attribute(tag, "phx-submit")}, tag =~ "id=" and tag =~ "phx-change"}
        end
      end)
    end

    # Which components draw a box, to a fixpoint: one with box markup of its own, or one that
    # calls another that has. `message_box/1` is the first kind, `open_question/1` the second.
    defp box_components(sources) do
      bodies = Map.new(Enum.flat_map(sources, fn {_path, source} -> components(source) end))

      Stream.iterate(MapSet.new(), fn known ->
        for {name, body} <- bodies, holds_a_box?(body, known), into: MapSet.new(), do: name
      end)
      |> Stream.chunk_every(2, 1)
      |> Enum.find_value(fn [known, next] -> if MapSet.equal?(known, next), do: known end)
    end

    # Every `def name(assigns)` with markup of its own, as `{name, markup}`. Splitting at the
    # heads is what ties a sigil to its function: each belongs to the nearest head above it,
    # which is how every component in this layer is written.
    defp components(source) do
      source
      |> String.split(~r/\bdefp?\s+(?=[a-z_][\w?!]*\(assigns\))/)
      |> Enum.flat_map(fn part ->
        case Regex.run(~r/^([a-z_][\w?!]*)\(assigns\)/, part) do
          [_whole, name] -> [{name, heex_sigils(part)}]
          nil -> []
        end
      end)
    end

    # The markup a file holds and not its prose: `core_components.ex`'s moduledoc names
    # `<.form>` in a sentence, and reading that as a form made every `<.input>` after it part of
    # its body. A template is markup whole; in Elixir, markup is what sits inside `~H"""`.
    defp markup(path, source) do
      if Path.extname(path) == ".heex", do: source, else: heex_sigils(source)
    end

    defp heex_sigils(source) do
      source
      |> String.split(~s(~H"""))
      |> Enum.drop(1)
      |> Enum.map_join("\n", fn chunk -> chunk |> String.split(~s(""")) |> hd() end)
    end

    # Each form's opening tag and the markup inside it. HTML forms do not nest, so the first
    # close after a form is that form's; `<form>` and `<.form>` are both counted.
    defp forms(markup) do
      markup
      |> String.split(~r/<\.?form(?=[\s>])/)
      |> Enum.drop(1)
      |> Enum.map(fn chunk ->
        [form | _rest] = String.split(chunk, ~r/<\/\.?form>/, parts: 2)
        tag_and_body(form)
      end)
    end

    # A box is a textarea or an input a person types into, written here or drawn by one of
    # `drawn`. A `<.input>` with no `type` is a text field, which is why the absent case counts;
    # a select, a radio and a hidden field are not boxes, because nothing is typed in them.
    defp holds_a_box?(body, drawn) do
      Enum.any?(fields(body), fn
        {"textarea", _attrs} -> true
        {"select", _attrs} -> false
        {"input", attrs} -> attribute(attrs, "type") in [nil | ~w(text email password url number)]
      end) or calls_a_box?(body, drawn)
    end

    defp calls_a_box?(body, drawn) do
      ~r/<(?:\.|[A-Z][\w.]*\.)([a-z_][\w?!]*)(?=[\s\/>])/
      |> Regex.scan(body)
      |> Enum.any?(fn [_whole, name] -> MapSet.member?(drawn, name) end)
    end

    defp fields(body) do
      ~r/<(?:\.|[A-Z][\w.]*\.)?(input|textarea|select)(?=[\s\/>])/
      |> Regex.scan(body, return: :index)
      |> Enum.map(fn [{at, len}, {name_at, name_len}] ->
        rest = binary_part(body, at + len, byte_size(body) - at - len)
        {binary_part(body, name_at, name_len), rest |> tag_and_body() |> elem(0)}
      end)
    end

    defp attribute(tag, name) do
      case Regex.run(~r/#{name}="([^"]*)"/, tag) do
        nil -> nil
        [_whole, value] -> value
      end
    end

    # A tag ends at the first `>` outside a HEEx `{…}`, which is where `value={"write-#{@name}"}`
    # and `phx-change={JS.push(…)}` would otherwise cut it short.
    defp tag_and_body(chunk), do: tag_and_body(chunk, 0, 0)

    defp tag_and_body(chunk, _depth, index) when index >= byte_size(chunk), do: {chunk, ""}

    defp tag_and_body(chunk, depth, index) do
      case {binary_part(chunk, index, 1), depth} do
        {"{", _} ->
          tag_and_body(chunk, depth + 1, index + 1)

        {"}", _} ->
          tag_and_body(chunk, depth - 1, index + 1)

        {">", 0} ->
          {binary_part(chunk, 0, index), binary_part(chunk, index, byte_size(chunk) - index)}

        _other ->
          tag_and_body(chunk, depth, index + 1)
      end
    end
  end
end
