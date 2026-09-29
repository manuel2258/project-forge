defmodule Forge.Repo.Migrations.QuestionOptionsCarryDetail do
  @moduledoc """
  An option became a headline and a sentence, and the recommendation moved from `default` onto
  its option (`docs/design/job-prompt.md` § Output format).

  `questions.options` goes from a `varchar[]` of labels to `jsonb`, a list of
  `{label, detail, recommended}`, and `questions.default` goes. A row recorded before keeps every
  option as a label with no detail, in its order, and its old default as the recommended one —
  so a question still open when this runs is still answerable, and its form still starts on what
  the agent recommended.
  """

  use Ecto.Migration

  def up do
    rename table(:questions), :options, to: :legacy_options

    alter table(:questions) do
      add :options, :jsonb, null: false, default: fragment("'[]'::jsonb")
    end

    flush()

    # `ORDER BY t.n` is the guarantee of the order; without it Postgres keeps the order of the
    # `unnest ... WITH ORDINALITY` it aggregates in practice, so the backfill test cannot tell the
    # two apart — an equivalent mutant as observed, kept because practice is not a promise.
    execute("""
    UPDATE questions SET options = COALESCE((
      SELECT jsonb_agg(
               jsonb_build_object(
                 'label', t.label,
                 'detail', NULL,
                 'recommended', COALESCE(t.label = questions."default", false)
               )
               ORDER BY t.n
             )
      FROM unnest(questions.legacy_options) WITH ORDINALITY AS t(label, n)
    ), '[]'::jsonb)
    """)

    alter table(:questions) do
      remove :legacy_options
      remove :default
    end
  end

  def down do
    alter table(:questions) do
      add :legacy_options, {:array, :string}, null: false, default: []
      add :default, :string
    end

    flush()

    execute("""
    UPDATE questions SET
      legacy_options = ARRAY(
        SELECT t.option->>'label'
        FROM jsonb_array_elements(questions.options) WITH ORDINALITY AS t(option, n)
        ORDER BY t.n
      ),
      "default" = (
        SELECT option->>'label'
        FROM jsonb_array_elements(questions.options) AS option
        WHERE (option->>'recommended')::boolean
        LIMIT 1
      )
    """)

    alter table(:questions) do
      remove :options
    end

    rename table(:questions), :legacy_options, to: :options
  end
end
