defmodule Forge.Look.Setups.TicketText do
  @moduledoc """
  A ticket's text on Steps (`docs/design/ui.md` § Steps; ticket 80), in the cases its criteria name:
  project `look-text`, tickets admitted through `Forge.Operator` so each has a real `ticket`
  version, and one release whose note is such a version too.

  - `long` — headings, a list, paragraphs with single newlines, a fenced block with a line over 200
    characters, a wide table, a URL over 300, markup, every remote kind of picture, and two
    attached pictures: `top.png` among the first lines and `below.png` well past the twelfth.
  - `short` — three lines, which fit under the cut.
  - `title_only` — no body, with one attached file.
  - `edited` — admitted with one text and rewritten as another, which is what Steps draws.
  - `release` — a release in progress with a long Markdown note.

  Users: `member` (an admin of the project). Paths: `long`, `short`, `title_only`, `edited` and
  `release` (each one's Steps), `long_docs` (Docs of the long one). Both pictures are real, small
  PNGs (a solid blue and a solid orange, 240 × 100), so a browser draws and fetches them. Made-up
  data only.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures, only: [funded!: 1, workflow_map: 0, ticket_fixture: 1]
  import Forge.MergeFixtures, only: [jump_files: 0]
  import Forge.ProjectFixtures, only: [commit_files!: 3]

  alias Forge.{Artifacts, Attachments, Operator, Projects, Tickets}
  alias Forge.Attachments.Batch

  @blue "iVBORw0KGgoAAAANSUhEUgAAAPAAAABkCAIAAAA3wCqQAAAA1UlEQVR42u3SAQkAAAgEsQ9mJnMayxzKYAmOS/XAG5EAQ4OhwdBgaAwNhgZDg6HB0BgaDA2GBkODoTE0GBoMDYYGQ2NoMDQYGgwNhsbQYGgwNBgaDI2hwdBgaDA0GBpDg6HB0GBoDA2GBkODocHQGBoMDYYGQ4OhMTQYGgwNhgZDY2gwNBgaDA2GxtBgaDA0GBoMjaHB0GBoMDQYGkODocHQYGgwNIYGQ4OhwdAYGgwNhgZDg6ExNBgaDA2GBkNjaDA0GBoMDYbG0GBoMDQYGgyNoeGOBa9Yh2oznq02AAAAAElFTkSuQmCC"
  @orange "iVBORw0KGgoAAAANSUhEUgAAAPAAAABkCAIAAAA3wCqQAAAA1UlEQVR42u3SAQkAAAgEsY9jTnMaxhzKYAmOy3TBG5EAQ4OhwdBgaAwNhgZDg6HB0BgaDA2GBkODoTE0GBoMDYYGQ2NoMDQYGgwNhsbQYGgwNBgaDI2hwdBgaDA0GBpDg6HB0GBoDA2GBkODocHQGBoMDYYGQ4OhMTQYGgwNhgZDY2gwNBgaDA2GxtBgaDA0GBoMjaHB0GBoMDQYGkODocHQYGgwNIYGQ4OhwdAYGgwNhgZDg6ExNBgaDA2GBkNjaDA0GBoMDYbG0GBoMDQYGgyNoeGOBW7A2tNbn9WbAAAAAElFTkSuQmCC"

  @long_line String.duplicate("long_code_line_that_does_not_wrap_", 6)
  @long_url "https://example.com/" <> String.duplicate("a-very-long-path-segment/", 12)

  @long """
  Checkout drops the order on a slow phone.

  ![top](attachments/top.png)

  ## What happens

  Press **Pay** and the page
  shows a spinner, then
  goes back to the cart.

  - the cart is emptied
  - the card is not charged
  - the spinner never stops

  ## Steps to reproduce

  1. Open the shop on a phone.
  2. Add two items.
  3. Press Pay on a slow connection.

  ```
  #{@long_line}
  ```

  | column one | column two | column three | column four | column five | column six |
  | --- | --- | --- | --- | --- | --- |
  | a long cell that does not fit | another long cell | and a third | a fourth | a fifth | a sixth |

  See #{@long_url}

  <script>alert(1)</script>

  ![remote](https://evil.example/a.png)
  ![relative](//evil.example/b.png)
  ![inline](data:image/png;base64,AAAA)
  ![app](/oidc/x)

  ## Later in the text

  Below the cut, and not fetched until the text is opened:

  ![below](attachments/below.png)

  The end of the text.
  """

  @note """
  Everything merged since the last release.

  - Sound toggle in settings
  - Pause menu keyboard navigation
  - The score on the end screen

  ## Not in this one

  Leave the font atlas out, it is still in review.

  One line
  then the next.

  ## Upgrading

  Nothing to do. Nothing to do. Nothing to do. Nothing to do. Nothing to do. Nothing to do.
  Nothing to do. Nothing to do. Nothing to do. Nothing to do. Nothing to do. Nothing to do.

  - a
  - b
  - c

  The end of the note.
  """

  @impl true
  def build do
    member = user_fixture()

    name = "look-text"
    File.rm_rf!(Path.join(Projects.repos_dir(), name <> ".git"))
    {:ok, project} = Projects.register_named(name, "main", member)

    commit_files!(
      Projects.repo_path(project),
      "main",
      Map.put(jump_files(), "README.md", "# Game\n")
    )

    funded!(project)

    pictures = [{"top.png", Base.decode64!(@blue)}, {"below.png", Base.decode64!(@orange)}]

    long = admit!(project, member, "Checkout drops the order", @long, pictures)
    short = admit!(project, member, "A short report", "One line.\nTwo.\nThree.", [])

    title_only =
      admit!(project, member, "Nothing but a title", "", [{"top.png", Base.decode64!(@blue)}])

    edited = admit!(project, member, "Rewritten text", "The first text, as admitted.", [])

    {:ok, _} =
      Operator.edit(
        Tickets.get!(edited.id),
        member,
        "ticket",
        "# Rewritten text\n\nThe second text, which is what Steps draws.\n"
      )

    release =
      ticket_fixture(%{
        project: project,
        title: "0.40.0",
        number: 99,
        branch: "ticket/99",
        workflow: Map.put(workflow_map(), "release", true)
      })

    {:ok, _} =
      Artifacts.record_version(release.id, "ticket", :document, :system, %{
        content: "# 0.40.0\n\n" <> @note
      })

    path = &"/tickets/#{project.name}/#{&1.number}"

    %{
      users: %{"member" => member},
      paths: %{
        "long" => path.(long),
        "long_docs" => path.(long) <> "?tab=docs",
        "short" => path.(short),
        "title_only" => path.(title_only),
        "edited" => path.(edited),
        "release" => path.(release)
      }
    }
  end

  defp admit!(project, member, title, body, pictures) do
    {:ok, ticket} =
      Operator.admit(project, member, %{
        title: title,
        body: body,
        on_hold: true,
        attachments: batch(project, member, pictures)
      })

    Tickets.get!(ticket.id)
  end

  defp batch(project, user, files) do
    uploads =
      for {name, bytes} <- files do
        path = Path.join(System.tmp_dir!(), "look-text-#{System.unique_integer([:positive])}")
        File.write!(path, bytes)
        {:ok, upload} = Attachments.stage(project, user, {:file, path}, name)
        File.rm(path)
        %{id: upload.id, name: name}
      end

    %Batch{uploads: uploads}
  end
end
