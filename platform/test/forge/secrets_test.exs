defmodule Forge.SecretsTest do
  @moduledoc """
  A project's secrets at rest (`docs/design/secrets.md` § What a secret is): who may write them,
  that a value is never read back by accident, and that deleting one destroys it.
  """

  use Forge.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures

  alias Forge.Credentials.Credential
  alias Forge.Events.Event
  alias Forge.{Operator, Secrets}
  alias Forge.Provisioning.Vault
  alias Forge.Secrets.Secret

  @value "sk_test_51Hx-the-project's-own"

  setup do
    project = project_fixture()
    %{project: project, admin: member_fixture(project, :admin)}
  end

  # The column itself, selected by name: the only way anything reads it.
  defp stored(%Secret{id: id}),
    do: Repo.one(from s in Secret, where: s.id == ^id, select: s.value)

  defp events(type), do: Repo.all(from e in Event, where: e.type == ^type, order_by: e.seq)

  defp errors(changeset), do: errors_on(changeset)

  describe "setting" do
    test "a new secret is version 1, sealed, and named in an event that carries no value", %{
      project: project,
      admin: admin
    } do
      assert {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)

      assert secret.version == 1
      assert secret.set_by_id == admin.id
      assert secret.value == nil

      sealed = stored(secret)
      refute sealed =~ @value
      assert Secret.open(sealed) == {:ok, @value}

      assert [event] = events("secret.set")
      assert event.project_id == project.id
      assert event.actor == %{"kind" => "user", "id" => admin.id}

      assert event.payload == %{
               "project" => project.name,
               "secret_id" => secret.id,
               "name" => "STRIPE_TEST_KEY",
               "version" => 1
             }

      refute inspect(event) =~ @value
    end

    test "setting it again is the next version of the same row, and the old value is gone", %{
      project: project,
      admin: admin
    } do
      {:ok, first} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)
      other = member_fixture(project, :admin)

      assert {:ok, second} =
               Operator.set_secret(project, other, "STRIPE_TEST_KEY", "sk_test_rotated-value")

      assert second.id == first.id
      assert second.version == 2
      assert second.set_by_id == other.id
      assert Secret.open(stored(second)) == {:ok, "sk_test_rotated-value"}
      assert [%{version: 2}] = Secrets.list(project)
      assert [1, 2] = Enum.map(events("secret.set"), & &1.payload["version"])
    end

    test "they are listed by name", %{project: project, admin: admin} do
      {:ok, _} = Operator.set_secret(project, admin, "B_KEY", @value)
      {:ok, _} = Operator.set_secret(project, admin, "A_KEY", @value)

      assert ["A_KEY", "B_KEY"] = Enum.map(Secrets.list(project), & &1.name)
    end

    test "each project's names are its own", %{project: project, admin: admin} do
      elsewhere = project_fixture()
      their_admin = member_fixture(elsewhere, :admin)

      {:ok, ours} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)
      {:ok, theirs} = Operator.set_secret(elsewhere, their_admin, "STRIPE_TEST_KEY", @value)

      assert ours.id != theirs.id
      assert theirs.version == 1
      assert [%{id: id}] = Secrets.list(project)
      assert id == ours.id
    end

    test "a name a job's environment needs is refused, and so is one that is not a name", %{
      project: project,
      admin: admin
    } do
      assert {:error, changeset} =
               Operator.set_secret(project, admin, "ANTHROPIC_BASE_URL", @value)

      assert errors(changeset).name == ["is reserved: a job's environment needs it for itself"]

      assert {:error, changeset} = Operator.set_secret(project, admin, "stripe_key", @value)
      assert [message] = errors(changeset).name
      assert message =~ "upper case"

      assert {:error, changeset} = Operator.set_secret(project, admin, nil, @value)
      assert errors(changeset).name != []

      # Refused by the rule, before the name is a query parameter: Postgres rejects a NUL in text
      # outright, and that raised — taking the page's process down with the value in its last
      # message — before anything here had looked at the name.
      assert {:error, changeset} = Operator.set_secret(project, admin, "KEY\0X", @value)
      assert [message] = errors(changeset).name
      assert message =~ "upper case"

      assert Secrets.list(project) == []
      assert events("secret.set") == []
    end

    test "a value is at least eight characters, at most 32 KiB, and never carries a NUL", %{
      project: project,
      admin: admin
    } do
      refused = [
        {"seven77", "must be at least 8 characters"},
        {String.duplicate("a", 32 * 1024 + 1), "must be at most 32 KiB"},
        {"before\0after", "cannot contain a NUL byte; no environment can carry one"},
        {"   short\n", "must be at least 8 characters"},
        # Characters, not bytes, at the floor: ten bytes, five characters.
        {"ééééé", "must be at least 8 characters"},
        # Bytes, not characters, at the ceiling: 8,193 characters, 32,772 bytes.
        {String.duplicate("😀", 8193), "must be at most 32 KiB"},
        {nil, "is required"}
      ]

      for {value, message} <- refused do
        assert {:error, changeset} = Operator.set_secret(project, admin, "KEY", value)
        assert errors(changeset).value == [message], inspect(value)
      end

      assert {:ok, _} = Operator.set_secret(project, admin, "EIGHT", "8 chars!")
      assert {:ok, _} = Operator.set_secret(project, admin, "EIGHT_WIDE", "éééééééé")

      assert {:ok, _} =
               Operator.set_secret(project, admin, "BIG", String.duplicate("a", 32 * 1024))
    end

    test "the ends are trimmed and a browser's CRLF is read as a line break", %{
      project: project,
      admin: admin
    } do
      pem = "-----BEGIN KEY-----\r\nabcdefgh\r\n-----END KEY-----\r\n"
      {:ok, secret} = Operator.set_secret(project, admin, "DEPLOY_KEY", "  " <> pem)

      assert Secret.open(stored(secret)) ==
               {:ok, "-----BEGIN KEY-----\nabcdefgh\n-----END KEY-----"}
    end

    # The unique index is what stops two admins making the same new name at once; the lock in
    # `Secrets.set/4` cannot, since there is no row yet to lock. Inserting a second live row
    # directly is that race with the first insert already committed.
    test "a second live secret of the same name is refused, not raised", %{
      project: project,
      admin: admin
    } do
      {:ok, _} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)

      attrs = %{
        project_id: project.id,
        name: "STRIPE_TEST_KEY",
        version: 1,
        set_at: DateTime.utc_now(:second)
      }

      assert {:error, changeset} = %Secret{} |> Secret.changeset(attrs, @value) |> Repo.insert()

      assert ["was set by somebody else at the same moment; set it again"] =
               errors(changeset).name
    end
  end

  describe "the value is never read back by accident" do
    test "an ordinary query does not load it, and inspect would not show it", %{
      project: project,
      admin: admin
    } do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)

      assert Repo.get!(Secret, secret.id).value == nil
      assert [%Secret{value: nil}] = Secrets.list(project)

      sealed = stored(secret)
      refute inspect(%{secret | value: sealed}) =~ sealed
    end

    # Each table seals under its own label, so ciphertext moved between columns opens nowhere. The
    # map sealed here is a secret's own shape, so only the label can be what refuses it.
    test "another table's ciphertext does not open as a secret, nor the reverse", %{
      project: project,
      admin: admin
    } do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)

      for label <- ["forge/credentials/v1", "forge/provisioning/v1"] do
        assert Secret.open(Vault.seal(%{"value" => @value}, label)) == :error, label
      end

      assert Credential.open(stored(secret)) == :error

      assert Forge.Provisioning.Credential.secret(%Forge.Provisioning.Credential{
               secret: stored(secret)
             }) == :error

      assert Secret.open(nil) == :error
    end

    # The Vault opens any map sealed under this label; only one with a string value is a secret.
    test "a sealed map that is not a secret's shape does not open as one" do
      for shape <- [%{"token" => "t"}, %{"value" => 12_345_678}] do
        assert Secret.open(Vault.seal(shape, "forge/secrets/v1")) == :error
      end
    end
  end

  describe "deleting" do
    test "destroys the value, keeps the row, and frees the name", %{
      project: project,
      admin: admin
    } do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)
      {:ok, _} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", "sk_test_rotated-value")

      assert {:ok, deleted} = Operator.delete_secret(project, admin, secret.id)
      assert deleted.deleted_at

      row = Repo.get!(Secret, secret.id)
      assert row.deleted_at
      assert stored(row) == nil
      assert Secrets.list(project) == []

      assert [event] = events("secret.deleted")
      assert event.project_id == project.id

      assert event.payload == %{
               "project" => project.name,
               "secret_id" => secret.id,
               "name" => "STRIPE_TEST_KEY",
               "version" => 2
             }

      assert {:ok, again} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)
      assert again.id != secret.id
      assert again.version == 1

      # A name and a version do not say which secret: this one is version 1 as the first was.
      # The id does, and it is what a job's record will name (`secrets.md` § Delivery).
      assert [first, _second, third] = events("secret.set")
      assert first.payload["version"] == third.payload["version"]
      assert first.payload["secret_id"] == secret.id
      assert third.payload["secret_id"] == again.id
    end

    test "only once", %{project: project, admin: admin} do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)
      {:ok, _} = Operator.delete_secret(project, admin, secret.id)

      assert Operator.delete_secret(project, admin, secret.id) == {:error, :not_found}
      assert length(events("secret.deleted")) == 1
    end

    test "an id is resolved inside the project it was sent for", %{
      project: project,
      admin: admin
    } do
      elsewhere = project_fixture()
      their_admin = member_fixture(elsewhere, :admin)
      {:ok, theirs} = Operator.set_secret(elsewhere, their_admin, "STRIPE_TEST_KEY", @value)

      assert Operator.delete_secret(project, admin, theirs.id) == {:error, :not_found}
      assert Operator.delete_secret(project, admin, "not-a-uuid") == {:error, :not_found}
      assert Operator.delete_secret(project, admin, nil) == {:error, :not_found}

      assert Secret.open(stored(theirs)) == {:ok, @value}
      assert [_] = Secrets.list(elsewhere)
    end

    # The database refuses a live row without a value and a deleted one with a value, so neither
    # half of a deletion can be written without the other.
    test "the database keeps value and deletion together", %{project: project, admin: admin} do
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)

      assert_raise Postgrex.Error, ~r/value_while_live/, fn ->
        Repo.update_all(from(s in Secret, where: s.id == ^secret.id), set: [value: nil])
      end

      assert_raise Postgrex.Error, ~r/value_while_live/, fn ->
        Repo.update_all(from(s in Secret, where: s.id == ^secret.id),
          set: [deleted_at: DateTime.utc_now(:second)]
        )
      end
    end
  end

  describe "who may" do
    test "a member who is not an admin can do neither", %{project: project, admin: admin} do
      member = member_fixture(project, :member)
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)

      assert Operator.set_secret(project, member, "STRIPE_TEST_KEY", "sk_test_overwritten") ==
               {:error, :forbidden}

      assert Operator.set_secret(project, member, "OTHER_KEY", @value) == {:error, :forbidden}
      assert Operator.delete_secret(project, member, secret.id) == {:error, :forbidden}

      assert Secret.open(stored(secret)) == {:ok, @value}
      assert [%{version: 1}] = Secrets.list(project)
    end

    test "an admin of another project can do neither", %{project: project, admin: admin} do
      stranger = member_fixture(project_fixture(), :admin)
      {:ok, secret} = Operator.set_secret(project, admin, "STRIPE_TEST_KEY", @value)

      assert Operator.set_secret(project, stranger, "OTHER_KEY", @value) == {:error, :forbidden}
      assert Operator.delete_secret(project, stranger, secret.id) == {:error, :forbidden}
      assert [_] = Secrets.list(project)
    end
  end

  # A project whose repository has no commit yet — what a new one is until its first push — has
  # no workflow, and so names nothing: not the same answer as a workflow that is refused.
  test "a repository with no commit receives nothing yet" do
    bare = Path.join(System.tmp_dir!(), "empty-#{System.unique_integer([:positive])}.git")
    :ok = Forge.Git.init_bare(bare)
    on_exit(fn -> File.rm_rf!(bare) end)

    assert Secrets.received_by(project_fixture(repo_path: bare)) == :none
  end

  # The latest run that held it, by the log's order, for every secret in one query; a secret no run
  # held is not a key.
  test "when a run last held each secret", %{project: project, admin: admin} do
    {:ok, held} = Operator.set_secret(project, admin, "HELD_KEY", @value)
    {:ok, never} = Operator.set_secret(project, admin, "NEVER_KEY", @value)

    payload = %{
      "held" => [%{"secret_id" => held.id, "name" => "HELD_KEY", "version" => 1}],
      "gone" => []
    }

    # An earlier run, an hour before: the log is append-only, so its time is given as it is written.
    Repo.insert!(%Event{
      project_id: project.id,
      actor: %{"kind" => "system", "id" => nil},
      type: "job.secrets",
      payload: payload,
      inserted_at: DateTime.add(DateTime.utc_now(:second), -3600)
    })

    {:ok, latest} =
      Forge.Events.append("job.secrets", :system, %{project_id: project.id, payload: payload})

    assert Secrets.last_held(project, [held, never]) == %{held.id => latest.inserted_at}
    assert Secrets.last_held(project, []) == %{}
  end

  describe "for the wire" do
    # A value this node cannot open — a rotated `secret_key_base` — is named, and nothing is sealed:
    # a job handed some of what it names and not the rest fails somewhere harder to read.
    test "a value that will not open is named and nothing is sealed", %{
      project: project,
      admin: admin
    } do
      {:ok, good} = Operator.set_secret(project, admin, "GOOD_KEY", @value)
      {:ok, bad} = Operator.set_secret(project, admin, "BAD_KEY", @value)
      other_key = :crypto.strong_rand_bytes(32)

      sealed_elsewhere =
        Plug.Crypto.MessageEncryptor.encrypt(
          Jason.encode!(%{"value" => @value}),
          "forge/secrets/v1",
          other_key,
          "unused"
        )

      Repo.update_all(from(s in Secret, where: s.id == ^bad.id), set: [value: sealed_elsewhere])

      {found, []} = Secrets.resolve(project.id, ["GOOD_KEY", "BAD_KEY"])
      worker = %Forge.Workers.Worker{token_hash: String.duplicate("a", 64)}

      assert Secrets.for_wire(found, worker, Ecto.UUID.generate()) ==
               {:error, {:unreadable, ["BAD_KEY"]}}

      assert {:ok, _sealed} =
               Secrets.for_wire(
                 Enum.filter(found, &(&1.id == good.id)),
                 worker,
                 Ecto.UUID.generate()
               )
    end
  end
end
