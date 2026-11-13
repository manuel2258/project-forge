defmodule Forge.Look.Setups.Templates do
  @moduledoc """
  One user with three provider credentials on the fake driver, for the credential rows of
  `/templates` (`docs/design/provisioning.md` § Putting the release's image into an account):
  `main` with a build running and four that ended in every way, among them a provider's words that
  are hostile and long; `empty`, which has never built; and `off`, whose automatic building is off.
  Users: `owner`. Paths: `templates`.

  The platform is given a made-up release, so the switch and *Build now* are drawn; the fake
  driver's default listing holds no snapshot of it, so *Build now* is offered where nothing runs.
  """

  @behaviour Forge.Look.Setups

  import Forge.AccountsFixtures
  import Forge.ImageBuildsFixtures, only: [credential_fixture: 2]

  alias Forge.ImageBuilds.Build
  alias Forge.Repo

  @impl true
  def build do
    Application.put_env(:forge, Forge.WorkerImage,
      release: %{
        "build" => "abcdef123456",
        "version" => "0.20.0",
        "protocol" => "1",
        "repository" => "ghcr.io/owner/forge-worker-image",
        "digest" => "sha256:" <> String.duplicate("a", 64),
        "raw_sha256" => String.duplicate("b", 64),
        "raw_size" => "4096"
      }
    )

    owner = user_fixture()
    main = credential_fixture(owner, %{name: "main"})
    credential_fixture(owner, %{name: "empty"})
    off = credential_fixture(owner, %{name: "off"})
    {:ok, _} = Forge.ImageBuilds.set_auto(owner, off.id, false)

    now = DateTime.utc_now()

    for {minutes, attrs} <- [
          {5, %{status: :running, template_name: "workers-hel"}},
          {200, %{status: :built, build: "111111111111"}},
          {900,
           %{
             status: :failed,
             message:
               "<b>server limit reached</b> " <> String.duplicate("the provider said no. ", 12)
           }},
          {2000,
           %{
             status: :abandoned,
             message:
               "abandoned at the time limit: the builder powers off only after writing and reading back a verified image, so it never did"
           }}
        ] do
      Repo.insert!(
        struct!(
          Build,
          Map.merge(
            %{
              provider_credential_id: main.id,
              build: "abcdef123456",
              started_at: DateTime.add(now, -minutes * 60)
            },
            attrs
          )
        )
      )
    end

    %{users: %{"owner" => owner}, paths: %{"templates" => "/templates"}}
  end
end
