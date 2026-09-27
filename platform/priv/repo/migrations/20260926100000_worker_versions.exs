defmodule Forge.Repo.Migrations.WorkerVersions do
  @moduledoc """
  What a machine is running, and what a snapshot carries (`docs/design/worker-channel.md`
  § Versions).

  - `workers.release`, `workers.build` and `workers.protocol` are what the machine said at its
    last join, refused or not. All null for a row that has not joined since this migration, which
    is every row now: nothing can be known about them until they speak.
  - `workers.image` is the image the machine was made from, copied from its template at creation
    like its size and figures. It is what lets a refused machine teach its template the protocol
    of *that* image and not of whatever the template names by the time the refusal arrives
    (`docs/design/provisioning.md` § A snapshot that speaks the wrong protocol). Null for rows made
    before it, which therefore teach nothing about a template that names an image.
  - `worker_templates.image_build` and `image_protocol` are the chosen snapshot's labels, read from
    the driver's listing when the template is saved, and the protocol learnt from a refusal. Null
    is unlabelled: unknown, not compatible.
  """

  use Ecto.Migration

  def change do
    alter table(:workers) do
      add :release, :string
      add :build, :string
      add :protocol, :integer
      add :image, :string
    end

    alter table(:worker_templates) do
      add :image_build, :string
      add :image_protocol, :integer
    end
  end
end
