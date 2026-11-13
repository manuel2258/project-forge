defmodule Forge.Look.Setups.Proposals do
  @moduledoc """
  The Proposals view (`7e`, `8a`–`8g`): `Forge.Look.Setups.Project`'s `game`, with a chat that
  ended with three proposals, ticket #44's job splitting it into four, and the save-format chat's
  two — one of them declined with a reason, and one more admitted as a ticket.

  Users: `admin`, `member`. Paths: `proposals`, `reader` (the first chat proposal open),
  `history`.
  """

  @behaviour Forge.Look.Setups

  import Forge.ForgeFixtures, only: [proposal_fixture: 1]

  alias Forge.{Conversations, Proposals, Tickets}

  @impl true
  def build do
    %{users: %{"admin" => admin} = users, paths: paths} = Forge.Look.Setups.Project.build()
    project = Forge.Repo.get_by!(Forge.Projects.Project, name: "game")

    {:ok, ci} = Conversations.open(project, "Why is the build so slow on CI?")

    [first | _] =
      for {file, title, body} <- [
            {"cache.md", "Cache textures by content hash",
             "The asset step keys its cache on the commit, so every push rebuilds all 212 textures.\n\nKeying each texture on a hash of its source and its import settings rebuilds only what changed."},
            {"split-ci.md", "Split the CI check into fast and full",
             "Run lint and unit tests on every push, the slow integration suite only before merge."},
            {"pin-image.md", "Pin the Elixir image by digest",
             "The tag moved twice last week and broke two builds without a code change."}
          ],
          do: proposal_fixture(%{job: ci, file: file, title: title, body: body})

    atlas = Tickets.get_by_number!(project, 44)
    [job | _] = Forge.Jobs.for_ticket(atlas.id)

    for {file, title, body} <- [
          {"sdf-offline.md", "Generate the SDF atlas offline",
           "Build the signed distance field once at asset time, not on first launch."},
          {"sdf-shader.md", "Swap the text shader to sample the SDF",
           "One shader for every size, replacing the four bitmap passes."},
          {"bitmap-fallback.md", "Keep the bitmap font as a fallback",
           "Old GPUs without derivatives keep today's path."},
          {"benchmark.md", "Benchmark text rendering before and after",
           "A fixed scene with 2,000 glyphs, frame time on three machines."}
        ],
        do: proposal_fixture(%{job: job, file: file, title: title, body: body})

    # The save-format chat's two (written by `Project`): one declined, and one more admitted.
    declined =
      Enum.find(Proposals.open(project.id), &(&1.artifact.name == "proposal-save-version.md"))

    {:ok, _} = Proposals.decline(declined.version.id, admin.id, "needs a server first")

    admitted =
      proposal_fixture(%{job: ci, file: "ci-cache-key.md", title: "Persist the CI cache"})

    {:ok, _ticket} = Proposals.accept(admitted.id, admin.id, nil, "feature")

    %{
      users: users,
      paths:
        Map.merge(paths, %{
          "reader" => "/projects/game?view=proposals&read=#{first.id}",
          "history" => "/projects/game?view=proposals"
        })
    }
  end
end
