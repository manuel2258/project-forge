defmodule Forge.Repo.Migrations.UsageInWeightedTokens do
  @moduledoc """
  What a run used stops being dollars and becomes **weighted tokens**, for every harness
  (`docs/design/capacity.md` § Usage in weighted tokens).

  Every past dollar figure is converted once, at 200,000 weighted tokens to the dollar. That rate is
  `ForgeCore.Usage.per_dollar/0` today and is written here as a literal on purpose: a migration
  must keep meaning what it meant when it ran, whatever that function is later calibrated to.

  - `job_runs`: `usage` (bigint), `tokens` (jsonb by kind, null where converted), `claude_cost_usd`
    (Claude Code's own dollar figure, kept for information and read by no cap and no pick) and
    `converted` (true where `usage` came from dollars and not from counted tokens). `cost_usd` goes.
  - `jobs` and `tickets`: `cost_usd` becomes `usage`, with `usage_converted` marking the rows that
    were converted rather than counted. A job or ticket that is later added to by counted runs
    stays marked: part of its figure is still a conversion.
  - `credentials`: `daily_limit_usd` becomes `daily_limit`, in weighted tokens.
  - `jobs.exhausted` "cost" is the token ceiling now.

  Irreversible in the one way that matters: a converted figure cannot be turned back into the
  dollars it was, since the rate was a guess, so `down` restores the columns and converts back at
  the same rate.
  """

  use Ecto.Migration

  # Weighted tokens to the dollar, as `ForgeCore.Usage.per_dollar/0` was when this was written.
  @rate 200_000

  def up do
    alter table(:job_runs) do
      add :usage, :bigint, null: false, default: 0
      add :tokens, :map
      add :claude_cost_usd, :decimal
      add :converted, :boolean, null: false, default: false
    end

    execute """
    UPDATE job_runs
       SET usage = round(cost_usd * #{@rate}),
           claude_cost_usd = cost_usd,
           converted = true
    """

    alter table(:job_runs) do
      remove :cost_usd
    end

    for table <- [:jobs, :tickets] do
      alter table(table) do
        add :usage, :bigint, null: false, default: 0
        add :usage_converted, :boolean, null: false, default: false
      end

      execute """
      UPDATE #{table}
         SET usage = round(cost_usd * #{@rate}),
             usage_converted = (cost_usd > 0)
      """

      alter table(table) do
        remove :cost_usd
      end
    end

    alter table(:credentials) do
      add :daily_limit, :bigint
    end

    execute "UPDATE credentials SET daily_limit = round(daily_limit_usd * #{@rate})"

    alter table(:credentials) do
      remove :daily_limit_usd
    end

    execute "UPDATE jobs SET exhausted = 'tokens' WHERE exhausted = 'cost'"
  end

  def down do
    execute "UPDATE jobs SET exhausted = 'cost' WHERE exhausted = 'tokens'"

    alter table(:credentials) do
      add :daily_limit_usd, :decimal
    end

    execute "UPDATE credentials SET daily_limit_usd = daily_limit / #{@rate}.0"

    alter table(:credentials) do
      remove :daily_limit
    end

    for table <- [:tickets, :jobs] do
      alter table(table) do
        add :cost_usd, :decimal, null: false, default: 0
      end

      execute "UPDATE #{table} SET cost_usd = usage / #{@rate}.0"

      alter table(table) do
        remove :usage
        remove :usage_converted
      end
    end

    alter table(:job_runs) do
      add :cost_usd, :decimal, null: false, default: 0
    end

    execute "UPDATE job_runs SET cost_usd = coalesce(claude_cost_usd, usage / #{@rate}.0)"

    alter table(:job_runs) do
      remove :usage
      remove :tokens
      remove :claude_cost_usd
      remove :converted
    end
  end
end
