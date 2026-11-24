defmodule Forge.Look.Setups.Pages do
  @moduledoc """
  Pages an agent wrote (`docs/design/pages.md`, `docs/design/ui.md` § Pages): a ticket with a form
  that has been filled in a little, a page whose name is long, an ordinary document beside them
  for the Docs list; a done ticket whose page is read only; and a project chat with a page of its
  own. The form is a few inputs saved through forge's library, which is what a page does. Made-up
  data: the bytes are a form and a few names, never a secret. Users: `member` (a project admin).
  A ticket resting in a human state that opens the form (`waiting`, and the queue's item of it),
  and a ticket in review in a project of its own whose form is pinned beside its decision
  (`review`). Paths: `ticket`, `docs`, `page`, `long`, `done_page`, `chat_page`, `chat`, `queue`,
  `waiting`, `review`.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures
  import ForgeWeb.PageDoorFixtures

  alias Forge.Look.Setups.Decision
  alias Forge.{Pages, Repo}

  @workflow Path.expand("../../../../../core/test/fixtures/workflow_example.yml", __DIR__)
  @external_resource @workflow

  @opens """
  version: 1
  initial: drafting
  states:
    drafting:
      prompt: agents/draft.md
      produces: [form@]
      budget: { turns: 10, tokens: 200k }
    filling:
      opens: form
    finished: {}
  transitions:
    - { from: drafting, to: filling }
    - { from: filling, to: finished }
  limits:
    ticket_tokens: 5M
  """

  # Inline, because a look's guard wants its cookie on every request and a sandboxed frame sends
  # none, so a script the page asks for by address would be refused (`pages_browser_test`).
  @library "../../../../priv/page/forge-page.js"
           |> Path.expand(__DIR__)
           |> File.read!()
           |> String.replace("</script>", "<\\/script>")
  @external_resource Path.expand("../../../../priv/page/forge-page.js", __DIR__)

  @form """
  <!doctype html>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Player text</title>
  <style>
    body { font: 16px/1.5 system-ui, sans-serif; margin: 0; padding: 20px; background: #fff; color: #1b1b1f; }
    label { display: block; margin: 14px 0 4px; font-weight: 600; }
    input, textarea { width: 100%; box-sizing: border-box; padding: 10px; font: inherit; border: 1px solid #99a; border-radius: 6px; }
    #note { margin-top: 18px; color: #556; }
  </style>
  <h1>Player text</h1>
  <label for="hero">The hero's name</label>
  <input id="hero" autocomplete="off">
  <label for="line">Their first line</label>
  <textarea id="line" rows="4"></textarea>
  <p id="note">Loading…</p>
  <script>#{@library}</script>
  <script>
    forge.ready.then(function (me) {
      var note = document.getElementById("note")
      note.textContent = me.readOnly ? "Read only: " + me.reason : "Filling this in as " + me.viewer
      ;["hero", "line"].forEach(function (key) {
        var field = document.getElementById(key)
        forge.get(key).then(function (entry) { if (entry) field.value = entry.value })
        field.addEventListener("input", function () { forge.set(key, field.value).catch(function () {}) })
      })
      forge.onChange(function (change) {
        var field = document.getElementById(change.key)
        if (field) field.value = change.deleted ? "" : change.value
      })
      forge.onReadOnly(function (state) {
        note.textContent = state.readOnly ? "Read only: " + state.reason : "Writable again"
      })
    })
  </script>
  """

  @impl true
  def build do
    member = user_fixture()
    project = project_fixture(%{name: "look-pages"}) |> join!(member)

    ticket = ticket_fixture(%{project: project, title: "Write the player text"})

    {:ok, _} =
      Forge.Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: "---\noutcome: done\n---\n# Refinement\n\nThe cast fills in a form over days.\n"
      })

    {form, _} = published!({:ticket, ticket.id}, "form", %{"index.html" => @form})
    {:ok, _} = Pages.put(form, "hero", "Ada", {:user, member.id})
    {_page, _} = published!({:ticket, ticket.id}, long_name(), %{"index.html" => @form})

    done = ticket_fixture(%{project: project, title: "Collect the cast's answers", number: 9})
    {done_form, _} = published!({:ticket, done.id}, "form", %{"index.html" => @form})
    {:ok, _} = Pages.put(done_form, "hero", "Grace", {:user, member.id})
    done |> Ecto.Changeset.change(status: :done) |> Repo.update!()

    chat = chat_fixture(%{project: project})
    {_notes, _} = published!({:chat, chat.id}, "notes", %{"index.html" => @form})

    {:ok, opens} = YamlElixir.read_from_string(@opens)

    waiting =
      ticket_fixture(%{
        project: project,
        title: "Fill in the cast's answers",
        number: 10,
        workflow: opens,
        state: "filling"
      })

    {_form, _} = published!({:ticket, waiting.id}, "form", %{"index.html" => @form})

    decision = Decision.project!("look-pages-review", File.read!(@workflow), member)
    review = Decision.changeset_ticket!(decision, member)
    {_form, _} = published!({:ticket, review.id}, "form", %{"index.html" => @form})

    %{
      users: %{"member" => member},
      paths: %{
        "ticket" => "/tickets/#{project.name}/#{ticket.number}",
        "docs" => "/tickets/#{project.name}/#{ticket.number}?tab=docs",
        "page" => "/tickets/#{project.name}/#{ticket.number}/pages/form",
        "long" => "/tickets/#{project.name}/#{ticket.number}/pages/#{long_name()}",
        "done_page" => "/tickets/#{project.name}/#{done.number}/pages/form",
        "chat" => "/chats/#{chat.id}",
        "chat_page" => "/chats/#{chat.id}/pages/notes",
        "queue" => "/",
        "waiting" => "/tickets/#{project.name}/#{waiting.number}",
        "review" => "/tickets/#{decision.name}/#{review.number}?tab=docs"
      }
    }
  end

  defp long_name, do: "player-text-for-the-whole-cast-of-the-game-with-every-line-they-speak"
end
