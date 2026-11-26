defmodule Forge.Repo.Migrations.TicketTakeovers do
  use Ecto.Migration

  # A ticket taken over by a person or a token to work on outside forge, and handed back
  # (`docs/design/outside-work.md`, `data-model.md`). **Breaking only in that it is a migration**:
  # no row exists until someone takes a ticket over, and a ticket's `takeover_id` is null for every
  # ticket there is.
  #
  # One row is both halves: the take-over's columns are set when it is made, the hand-back's are
  # null while it is open and written once, when the ticket is handed back.
  def change do
    create table(:ticket_takeovers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticket_id, references(:tickets, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :token_id, references(:git_tokens, type: :binary_id, on_delete: :nilify_all)
      add :via, :string, null: false
      add :state, :string, null: false
      add :head, :string
      add :taken_at, :utc_datetime, null: false

      # Insertion order, to the row: every time here is stored to the second, and two take-overs of a
      # ticket can follow one another inside one. Read by `Forge.Jobs.outside_of/1` alone.
      add :seq, :bigserial, null: false

      add :back_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :back_token_id, references(:git_tokens, type: :binary_id, on_delete: :nilify_all)
      add :back_via, :string
      add :to_state, :string
      add :note, :text
      add :back_head, :string
      add :commits, :map

      add :changeset_version_id,
          references(:artifact_versions, type: :binary_id, on_delete: :nilify_all)

      add :handed_back_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:ticket_takeovers, [:ticket_id, :taken_at])

    # One open take-over per ticket: a second is a second hold, and the engine refuses it by name.
    create unique_index(:ticket_takeovers, [:ticket_id],
             where: "handed_back_at IS NULL",
             name: :ticket_takeovers_one_open
           )

    create constraint(:ticket_takeovers, :ticket_takeovers_one_taker,
             check: "num_nonnulls(user_id, token_id) <= 1"
           )

    create constraint(:ticket_takeovers, :ticket_takeovers_note_limit,
             check: "note IS NULL OR char_length(note) <= 2000"
           )

    alter table(:tickets) do
      add :takeover_id, references(:ticket_takeovers, type: :binary_id, on_delete: :nilify_all)
    end

    create constraint(:tickets, :tickets_takeover_is_a_hold,
             check: "takeover_id IS NULL OR held_at IS NOT NULL"
           )
  end
end
