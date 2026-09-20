defmodule Forge.Repo.Migrations.WorkersRecordWhyACreateFailed do
  @moduledoc """
  A machine that was never made is the one an operator most needs told about.

  `Workers.create_machine/1` inserts the row, asks the driver, and returns the driver's error
  to the scheduler — which treats every error alike as *not right now* and offers the job again
  next pass. Nothing was logged, nothing was on the row, and nothing reached a page, so a node
  whose image was misconfigured created and swept a row every three minutes for ever and looked
  idle while doing it. That is how it was found.

  `last_error` is what the driver said, kept on the row that never became a machine.
  """

  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :last_error, :text
    end
  end
end
