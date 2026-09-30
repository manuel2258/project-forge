defmodule Forge.Repo.Migrations.WorkersUnhealthy do
  @moduledoc """
  A machine whose systemd stopped answering (`docs/design/worker-tier.md` § A machine whose
  systemd stops answering).

  - `workers.unhealthy_at` and `workers.unhealthy_reason` are when the machine said it can no
    longer run anything, and why. Set, nothing is placed on it; cleared when it joins again
    without saying so.
  - `workers.rebooted_at` is when the platform last told it to reboot. It outlives the episode,
    because it is what keeps a machine from being told twice within the hour.

  Microseconds, because the rule that answers a repeated question about the same episode compares
  the two: a whole second would let a second episode begin in the second the first was answered.
  """

  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :unhealthy_at, :utc_datetime_usec
      add :unhealthy_reason, :text
      add :rebooted_at, :utc_datetime_usec
    end
  end
end
