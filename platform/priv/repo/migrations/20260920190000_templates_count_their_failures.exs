defmodule Forge.Repo.Migrations.TemplatesCountTheirFailures do
  @moduledoc """
  A template counts the machines it failed to make, and carries the last reason.

  A recipe that does not work is a loop the platform never tires of: the scheduler wants
  capacity, the template fails, the sweep retires the row three minutes later, and the next pass
  starts again. On the node this was found on it ran for hours — first as local machines refusing
  `:no_image`, then as real Hetzner machines that booted, could not reach a platform on
  `localhost` and were destroyed at the timeout. The second kind costs money every turn.

  **Two columns and no third.** Disabled is derived — `failures >= limit` — rather than stored
  beside the counter, because a flag and a count are two facts about one thing and the day they
  disagree there is no way to say which is true. Enabling is setting the counter back to zero.

  `failures` counts *consecutive* ones: a worker reaching `ready` zeroes it, so a template that
  has made a hundred good machines is not disabled by three bad ones spread across a year.

  See `docs/design/provisioning.md` § A template that cannot make a working machine is taken out
  of service.
  """

  use Ecto.Migration

  def change do
    alter table(:worker_templates) do
      add :failures, :integer, null: false, default: 0
      add :last_error, :string
    end
  end
end
