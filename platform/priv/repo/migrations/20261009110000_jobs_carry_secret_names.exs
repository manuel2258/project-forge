defmodule Forge.Repo.Migrations.JobsCarrySecretNames do
  @moduledoc """
  The project secrets a job is handed, by name, written once when the job is made: a workflow
  job's from its state, a command's from its declaration, a conversation's from what the person
  opening it picked (`docs/design/secrets.md` § The workflow is the access list). On the row and
  not only in the spec, because a conversation has no spec, and because the scheduler and the
  assignment read it for every kind alike. Never a value.
  """

  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :secret_names, {:array, :string}, null: false, default: []
    end
  end
end
