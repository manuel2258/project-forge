defmodule Forge.Repo.Migrations.WorkersUnansweredCreate do
  @moduledoc """
  `workers.unanswered_create`: the platform has asked the row's driver to make the machine and
  has not heard back (`docs/design/provisioning.md` § Whose account). True from just before the
  create is sent until the driver answers, either way; a row still true when nothing is creating it
  is one whose create was cut off — the platform stopped mid-call — and may have a machine billing
  that its row never heard of. Only such a row is looked for at the provider before it is
  destroyed: a row whose create was refused has no machine, and asking for one with the credential
  the refusal was about would keep the row for ever.

  False for every existing row, which is what they were before there was a question to ask.
  """

  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :unanswered_create, :boolean, null: false, default: false
    end
  end
end
