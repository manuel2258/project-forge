defmodule Forge.Release do
  @moduledoc """
  Commands for the running release, where Mix does not exist. Invoke with
  `bin/forge eval 'Forge.Release.migrate()'` and friends; see the deployment guide.
  """

  @app :forge

  @doc "Runs pending migrations."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc "Rolls one repo back to `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc "Creates a confirmed operator who can log in with the password."
  def create_operator(email, password) do
    with_app(fn ->
      case Forge.Accounts.create_operator(email, password) do
        {:ok, user} -> IO.puts("created user #{user.email} (#{user.id})")
        {:error, changeset} -> fail(inspect(changeset.errors))
      end
    end)
  end

  @doc "Prints a new API token for the user, once."
  def create_token(email, name \\ "cli") do
    with_app(fn ->
      case Forge.Accounts.get_user_by_email(email) do
        nil -> fail("unknown user #{email}")
        user -> IO.puts(Forge.Accounts.create_api_token(user, name))
      end
    end)
  end

  @doc "Lists the user's API tokens by name."
  def list_tokens(email) do
    with_app(fn ->
      case Forge.Accounts.get_user_by_email(email) do
        nil -> fail("unknown user #{email}")
        user -> Enum.each(Forge.Accounts.list_api_tokens(user), &print_token/1)
      end
    end)
  end

  defp print_token(token), do: IO.puts("#{token.name}\t#{token.inserted_at}\t#{token.id}")

  @doc "Revokes the user's API tokens with that name."
  def revoke_token(email, name) do
    with_app(fn ->
      case Forge.Accounts.get_user_by_email(email) do
        nil -> fail("unknown user #{email}")
        user -> IO.puts("revoked #{Forge.Accounts.revoke_api_tokens(user, name)} token(s)")
      end
    end)
  end

  @doc "Registers a project; the bare repository is created if missing."
  def register_project(name, repo_path, default_branch \\ "main") do
    with_app(fn ->
      case Forge.Projects.register(%{
             name: name,
             repo_path: repo_path,
             default_branch: default_branch
           }) do
        {:ok, project} ->
          IO.puts("registered #{project.name} at #{Forge.Projects.repo_path(project)}")

        {:error, %Ecto.Changeset{} = changeset} ->
          fail(inspect(changeset.errors))

        {:error, reason} ->
          fail(inspect(reason))
      end
    end)
  end

  @doc "Prints a fresh VAPID key pair for web push, to put into the environment."
  def generate_vapid_keys do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
    IO.puts("FORGE_VAPID_PUBLIC_KEY=" <> Base.url_encode64(public_key, padding: false))
    IO.puts("FORGE_VAPID_PRIVATE_KEY=" <> Base.url_encode64(private_key, padding: false))
    :ok
  end

  # Starts the repo (not the whole app, so no scheduler runs) around a command.
  defp with_app(fun) do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _ -> fun.() end)
    end

    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end
