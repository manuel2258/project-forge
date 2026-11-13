defmodule Forge.Look.Setups.Changes do
  @moduledoc """
  A ticket's Changes view (`docs/design/ui.md` § Changes): `review` is in review with a
  changeset of three files, a `presentation.md` that quotes two of them and shows a screenshot, a
  `commit-message`, an approved refinement, a plan with an answered question, and
  its approval into `merged` waiting (`19d`, `19e`, `19g`, `18b`, `18f`); `wip` is implementing,
  with commits on its branch and no presentation yet (`19f`).

  Users: `member`. Paths: `review`, `files`, `commits`, `whole`, `wip`. The project is made by
  `Forge.Look.Setups.Decision`'s helper, and commits through plumbing by
  `Forge.ProjectFixtures.commit_files!/3`.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.MergeFixtures
  import Forge.ProjectFixtures, only: [commit_files!: 3]

  alias Forge.{Artifacts, Operator, Projects, Storage, Tickets}
  alias Forge.Look.Setups.Decision

  @workflow Path.expand("../../../../../core/test/fixtures/workflow_example.yml", __DIR__)
  @external_resource @workflow

  @icon Path.expand("../../../../priv/static/images/icon-192.png", __DIR__)
  @external_resource @icon

  @settings_before """
  defmodule Game.Settings do
    @moduledoc "What a player has chosen, saved with the game."

    @derive Jason.Encoder

    # Every field has a default, so a save written before a field existed still loads.
    #
    # The struct is the save file's shape: nothing else is written.
    #
    # Reading a save is `load/1`; writing one is `save/1`.

    defstruct difficulty: :normal,
              music: true

    def load(map), do: struct(__MODULE__, map)
    def save(settings), do: Map.from_struct(settings)
  end
  """

  @settings_after """
  defmodule Game.Settings do
    @moduledoc "What a player has chosen, saved with the game."

    @derive Jason.Encoder

    # Every field has a default, so a save written before a field existed still loads.
    #
    # The struct is the save file's shape: nothing else is written.
    #
    # Reading a save is `load/1`; writing one is `save/1`.

    defstruct difficulty: :normal,
              music: true,
              sound: true

    def toggle_sound(%__MODULE__{} = s),
      do: %{s | sound: !s.sound}

    def load(map), do: struct(__MODULE__, map)
    def save(settings), do: Map.from_struct(settings)
  end
  """

  @audio_before """
  defmodule Game.Audio do
    @moduledoc "Every sound the game makes goes through here."

    # The mixer is started once, when the game boots, and every effect after that is a call to
    # `play/1` with the effect's name. Music is an effect like any other: it loops.
    #
    # Nothing outside this module talks to the mixer.
    #
    # The names are the files under priv/sounds, without the extension.
    #
    # A name that is not a file is a no-op, logged once.
    #
    # Volume is the mixer's; this module never sets it.

    alias Game.Settings

    def init, do: Mixer.start()

    def play(name) do
      Mixer.play(name)
    end

    def stop, do: Mixer.stop()
  end
  """

  @audio_after """
  defmodule Game.Audio do
    @moduledoc "Every sound the game makes goes through here."

    # The mixer is started once, when the game boots, and every effect after that is a call to
    # `play/1` with the effect's name. Music is an effect like any other: it loops.
    #
    # Nothing outside this module talks to the mixer.
    #
    # The names are the files under priv/sounds, without the extension.
    #
    # A name that is not a file is a no-op, logged once.
    #
    # Volume is the mixer's; this module never sets it.

    alias Game.Settings

    def init do
      Mixer.start()
      Mixer.mute(!Settings.get(:sound))
    end

    def play(name) do
      if Settings.get(:sound) do
        Mixer.play(name)
      end
    end

    def stop, do: Mixer.stop()
  end
  """

  @test """
  defmodule Game.SettingsTest do
    use ExUnit.Case, async: true

    test "sound is on by default", do: assert(%Game.Settings{}.sound)
    test "an old save loads with sound on", do: assert(Game.Settings.load(%{}).sound)
    test "toggling flips it", do: refute(Game.Settings.toggle_sound(%Game.Settings{}).sound)
    test "it is saved", do: assert(Game.Settings.save(%Game.Settings{}).sound)
  end
  """

  @presentation """
  ---
  outcome: done
  ---
  # A sound switch in settings, saved with the game

  Settings gains a `sound` field next to `music`, on by default, so old saves load with sound
  on. `lib/game/settings.ex:12-17`

  Every effect goes through `Audio.play/1`, so the switch is checked in one place. Starting the
  mixer muted covers music that is already playing. `lib/game/audio.ex:17-26`

  The settings screen gets a row under Music, wired to `Settings.toggle_sound/1`.

  ![the settings screen, with the new row](screenshots/settings.png)

  ## How it was checked

  4 new tests in `test/game/settings_test.exs`; `bin/check --fast` passed in 21s.

  ## Worth a look

  The switch is read once at boot by the mixer, so it takes effect on the next sound, not
  mid-sound.
  """

  @impl true
  def build do
    member = user_fixture()
    project = Decision.project!("look-changes", File.read!(@workflow), member)
    repo = Projects.repo_path(project)

    commit_files!(repo, "main", %{
      "lib/game/settings.ex" => @settings_before,
      "lib/game/audio.ex" => @audio_before
    })

    review = review!(project, member)
    wip = wip!(project, member)
    base = "/tickets/#{project.name}/#{review.number}"

    whole =
      URI.encode_query(
        tab: "changes",
        sub: "files",
        file: "lib/game/audio.ex",
        lines: "17-26",
        para: "para-0-2"
      )

    %{
      users: %{"member" => member},
      paths: %{
        "review" => base <> "?tab=changes",
        "files" => base <> "?tab=changes&sub=files",
        "commits" => base <> "?tab=changes&sub=commits",
        "whole" => base <> "?" <> whole,
        "wip" => "/tickets/#{project.name}/#{wip.number}?tab=changes"
      }
    }
  end

  defp review!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Sound toggle in settings"}, {:user, member.id})

    repo = Projects.repo_path(project)
    commit_files!(repo, ticket.branch, %{"lib/game/settings.ex" => @settings_after})

    sha =
      commit_files!(repo, ticket.branch, %{
        "lib/game/audio.ex" => @audio_after,
        "test/game/settings_test.exs" => @test
      })

    {:ok, refinement} =
      Artifacts.record_version(ticket.id, "refinement.md", :document, :system, %{
        content: """
        ---
        outcome: done
        ---
        # Sound toggle in settings

        A player can turn sound effects off without muting music, and the choice survives a
        restart.
        """
      })

    approved!(refinement, member)

    {:ok, _} =
      Operator.edit(ticket, member, "plan.md", """
      # Plan

      Add `sound` to `Game.Settings`, check it in `Game.Audio.play/1`, add the row.

      ```question
      key: default
      text: Should sound start on or off for an existing save?
      options: [{label: "On", detail: An old save sounds as it did}, {label: "Off", detail: Silent until switched on}]
      blocking: false
      assumption: "On"
      ```
      """)

    {:ok, _} = Operator.answer(ticket, member, "default", %{choice: "On"})

    screenshot!(ticket, "screenshots/settings.png")
    changeset!(ticket, sha)

    {:ok, _} =
      Artifacts.record_version(ticket.id, "presentation.md", :presentation, :system, %{
        content: @presentation
      })

    commit_message!(
      ticket,
      "Add a sound toggle to settings\n\nPersists in the save file, defaults to on.\n"
    )

    pend_merge(ticket)
  end

  # Implementing, a second attempt, with the work so far on its branch and nothing to present.
  defp wip!(project, member) do
    {:ok, ticket} =
      Tickets.admit(project, %{title: "Persist the high score table"}, {:user, member.id})

    commit_files!(Projects.repo_path(project), ticket.branch, %{
      "lib/game/scores.ex" =>
        "defmodule Game.Scores do\n  def top(n), do: Enum.take([], n)\nend\n",
      "lib/game/settings.ex" => @settings_after
    })

    ticket
    |> Ecto.Changeset.change(state: "implementing", status: :active)
    |> Forge.Repo.update!()
  end

  # A picture the presentation names, as a job would have uploaded it: a blob in the store.
  defp screenshot!(ticket, name) do
    key = "look/changes/#{ticket.id}/settings.png"
    {:ok, _info} = Storage.put(key, File.read!(@icon))

    {:ok, _} =
      Artifacts.record_version(ticket.id, name, :blob, :system, %{blob_uri: Storage.uri(key)})
  end

  # A person's approval of one document version, as `Forge.Engine` records one.
  defp approved!(version, member) do
    {:ok, _changes} =
      Ecto.Multi.new()
      |> Artifacts.put_approval(
        :approval,
        version,
        member.id,
        :approved,
        %{"from" => "refining", "to" => "planning"},
        "reads right"
      )
      |> Forge.Repo.transaction()
  end
end
