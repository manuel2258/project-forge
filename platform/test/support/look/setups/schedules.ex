defmodule Forge.Look.Setups.Schedules do
  @moduledoc """
  What schedules leave on the screens (`docs/design/schedules.md`, `docs/design/ui.md` § Workflow,
  § The queue, § The details): a project `look-sched` with four types.

  - `chore` declares four schedules — `weekly-cleanup`, on and already fired once, so its last ticket
    is linked; `monthly-deps`, off; `hostile`, off, whose title and body hold markup and whose cron
    line is long; and `dependencies-by-monday-morning-before-anyone-is-in`, on by a second admin who
    is then demoted, so it switched itself off and says why.
  - `fragile` declares `nightly`, on, and its file was then broken, so it failed when due: the
    Workflow view lists it by name with the file's reason, and the queue holds its alert.
  - `plain` declares none, and `ship` is the release, which says nothing of schedules.

  Users: `admin` (a project admin) and `member`. Paths: `chore`, `fragile`, `plain`, `ship` (the
  Workflow view on each type), `queue`, `ticket` (the ticket `weekly-cleanup` admitted) and
  `by_hand` (one a person admitted).

  Made-up data only: nothing here is a secret. A name, title and cron line are text, whatever they
  hold; a body is Markdown with nothing resolved (`weekly-cleanup`'s holds a list, two lines, a
  picture, a link to an artifact and a link out; `hostile`'s holds markup, a remote picture and a
  long URL).
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ForgeFixtures, only: [funded!: 1, join!: 3]
  import Forge.ProjectFixtures, only: [commit_files!: 3]

  alias Forge.{Projects, Schedules, Tickets}

  @workflow Path.expand("../../../../../core/test/fixtures/workflow_example.yml", __DIR__)

  @prompts %{
    ".forge/agents/refine.md" => "Refine the ticket.\n",
    ".forge/agents/plan.md" => "Write a plan.\n",
    ".forge/agents/implement.md" => "Implement the plan.\n",
    ".forge/agents/verify.md" => "Verify the change.\n"
  }

  @chore """
  schedules:
    - name: weekly-cleanup
      cron: "0 6 * * MON"
      title: Weekly cleanup
      body: "Remove dead code from the last week:\\n\\n- stale comments\\n- unused functions\\n\\nOne line\\nthen the next. A picture ![shot](attachments/shot.png), the [plan](plan.md) and [the guide](https://example.com/guide)."
    - name: monthly-deps
      cron: "0 6 1 * *"
      title: Check the dependencies
      body: List what is out of date and why.
    - name: hostile
      cron: "*/15 0,6,12,18 1-7,15,20-25 JAN,MAR,MAY,JUL,SEP,NOV 1-5"
      title: "A <b>bold</b> title that is long enough that it would run off the side of a phone"
      body: "Nothing <script>alert(1)</script> to see. ![x](https://evil.example/x.png) and a very long line https://example.com/a-url-that-goes-on-and-on-and-on-and-on-and-on-and-on-and-on-and-on-and-on-and-on"
    - name: dependencies-by-monday-morning-before-anyone-is-in
      cron: "30 7 * * MON-FRI"
      title: Morning check
      body: Check the build is green.
  """

  @fragile """
  schedules:
    - name: nightly
      cron: "0 2 * * *"
      title: Nightly sweep
      body: Sweep.
  """

  @impl true
  def build do
    admin = user_fixture()
    member = user_fixture()
    second = user_fixture()

    File.rm_rf!(Path.join(Projects.repos_dir(), "look-sched.git"))
    {:ok, project} = Projects.register_named("look-sched", "main", admin)
    join!(project, member, :member)
    join!(project, second, :admin)
    funded!(project)

    plain = File.read!(@workflow)

    commit_files!(
      Projects.repo_path(project),
      "main",
      Map.merge(@prompts, %{
        ".forge/workflows/chore.yml" => plain <> "\n" <> @chore,
        ".forge/workflows/fragile.yml" => plain <> "\n" <> @fragile,
        ".forge/workflows/plain.yml" => plain,
        ".forge/workflows/ship.yml" => "release: true\n" <> plain,
        "README.md" => "# Game\n"
      })
    )

    {:ok, weekly} = Schedules.switch_on(project, admin, "chore", "weekly-cleanup")

    {:ok, _} =
      Schedules.switch_on(
        project,
        second,
        "chore",
        "dependencies-by-monday-morning-before-anyone-is-in"
      )

    {:ok, _} = Schedules.switch_on(project, admin, "fragile", "nightly")

    # The second admin loses the right, so what they switched on switches itself off with why.
    {:ok, _} = Projects.put_member(project, second, :member, admin)

    # The file then breaks, so `nightly` fails when it comes due; `weekly-cleanup` fires on the way.
    commit_files!(Projects.repo_path(project), "main", %{
      ".forge/workflows/fragile.yml" => "version: 1\nstates: [\n"
    })

    later = DateTime.add(weekly.fires_after, 8 * 86_400)
    results = Schedules.tick(later)

    {_, {:admitted, scheduled}} =
      Enum.find(results, &match?({"weekly-cleanup", {:admitted, _}}, &1))

    {:ok, by_hand} =
      Tickets.admit(
        project,
        %{title: "Fix the pause menu", body: "By hand.", ticket_type: "plain"},
        {:user, admin.id}
      )

    base = "/projects/#{project.name}?view=workflow"

    %{
      users: %{"admin" => admin, "member" => member},
      paths: %{
        "chore" => base <> "&type=chore",
        "fragile" => base <> "&type=fragile",
        "plain" => base <> "&type=plain",
        "ship" => base <> "&type=ship",
        "queue" => "/",
        "ticket" => "/tickets/#{project.name}/#{scheduled.number}",
        "by_hand" => "/tickets/#{project.name}/#{by_hand.number}"
      }
    }
  end
end
