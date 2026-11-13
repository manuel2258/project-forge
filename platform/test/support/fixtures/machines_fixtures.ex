defmodule Forge.MachinesFixtures do
  @moduledoc """
  Machines, templates and the log a machine leaves, for the machines pages' tests and the
  `machines` look (`docs/design/ui.md` § Machines). Made-up data only.
  """

  import Ecto.Query, only: [from: 2]
  import Forge.ForgeFixtures

  alias Forge.{Provisioning, Workers}
  alias Forge.Workers.Log

  @doc "A machine of `owner`'s, made by the fake provider unless `attrs` says otherwise."
  def machine_fixture(owner, attrs \\ %{}) do
    {:ok, worker, _token} =
      Workers.create(Map.merge(%{provider: "fake", managed: true, user_id: owner.id}, attrs))

    worker
  end

  @doc "A template of `owner`'s on the fake provider, assigned to `projects`."
  def template_fixture(owner, attrs \\ %{}, projects \\ []) do
    {:ok, template} =
      Provisioning.create_template(
        owner,
        Map.merge(
          %{
            name: "t-#{System.unique_integer([:positive])}",
            provider: "fake",
            memory: 8 * 1024 * 1024 * 1024,
            cores: 4,
            max_workers: 1
          },
          attrs
        )
      )

    for project <- projects, do: {:ok, _} = Provisioning.assign(owner, template.id, project.id)
    template
  end

  @doc """
  A fleet for `owner`, drawn on `12f`: two managed machines busy (a job on `game`'s ticket, a
  chat in `game`), one idle that its template's idle time will destroy, a permanent machine
  busy on `site`, a permanent one the platform turned away at its join, and a destroyed one whose
  log says why it went. Returns the projects, templates and machines by name.
  """
  def fleet_fixture(owner) do
    game = project_fixture(%{name: "arcade"}) |> join!(owner)
    site = project_fixture(%{name: "homepage"}) |> join!(owner)

    cx32 =
      template_fixture(owner, %{name: "hetzner-cx32", max_workers: 4, idle_ms: 15 * 60_000}, [
        game
      ])

    cx22 = template_fixture(owner, %{name: "hetzner-cx22", max_workers: 2, cores: 2}, [site])

    implementing = ready(machine_fixture(owner, Provisioning.Template.worker_attrs(cx32)))
    ticket = ticket_fixture(%{project: game, title: "Persist the high score table"})

    job_fixture(%{
      ticket: ticket,
      state: "implementing",
      attempt: 2,
      status: :running,
      worker_id: implementing.id
    })

    {:ok, implementing} = Workers.status(implementing, :busy)

    chatting = ready(machine_fixture(owner, Provisioning.Template.worker_attrs(cx32)))
    chat_fixture(%{project: game, status: :running, worker_id: chatting.id})
    {:ok, chatting} = Workers.status(chatting, :busy)

    idle = ready(machine_fixture(owner, Provisioning.Template.worker_attrs(cx32)))

    studio = ready(machine_fixture(owner, %{managed: false}))
    {:ok, _} = Workers.assign(owner, studio.id, site.id)
    {:ok, _} = Workers.assign(owner, studio.id, game.id)
    merge = ticket_fixture(%{project: game, title: "Merge the score table"})
    job_fixture(%{ticket: merge, state: "merging", status: :running, worker_id: studio.id})
    {:ok, studio} = Workers.status(studio, :busy)

    refused = machine_fixture(owner, %{managed: false})
    {:ok, _} = Workers.assign(owner, refused.id, site.id)

    {:error, _} =
      Workers.admit(refused.id, %{"protocol" => ForgeCore.WorkerProtocol.current() + 1})

    gone = machine_fixture(owner, Provisioning.Template.worker_attrs(cx22))
    logged!(gone)
    {:ok, gone} = Workers.status(gone, :destroyed)

    %{
      projects: %{game: game, site: site},
      templates: %{cx32: cx32, cx22: cx22},
      machines: %{
        implementing: implementing,
        chatting: chatting,
        idle: idle,
        studio: studio,
        refused: refused,
        gone: gone
      }
    }
  end

  defp ready(worker) do
    :ok =
      Workers.admit(worker.id, %{
        "protocol" => ForgeCore.WorkerProtocol.current(),
        "release" => "0.31.0 (8rh57whmgk6m)",
        "build" => "8rh57whmgk6m"
      })

    {:ok, worker} =
      Workers.ready(worker, %{
        "memory_budget" => 8 * 1024 * 1024 * 1024,
        "cores" => 4,
        "harness" => %{"driver" => "claude_code", "credential" => "per_job"}
      })

    worker
  end

  # What `12g` reads top down: made, joined, a job, out of memory, disconnected, destroyed.
  defp logged!(worker) do
    job_id = Ecto.UUID.generate()
    at = fn minutes -> DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -minutes * 60)) end

    :ok = Log.record(worker.id, "worker.created", :info, "Created from hetzner-cx22.")

    # The platform stamps its lines with its own clock; this one happened first.
    Forge.Repo.update_all(
      from(e in Forge.Workers.LogEntry,
        where: e.worker_id == ^worker.id and e.type == "worker.created"
      ),
      set: [at: DateTime.add(DateTime.utc_now(), -28 * 60)]
    )

    :ok =
      Log.accept(worker.id, %{
        "at" => at.(26),
        "type" => "worker.ready",
        "message" => "Build 0.31.0 ready, 2 cores, 8 GiB."
      })

    :ok =
      Log.accept(worker.id, %{
        "at" => at.(21),
        "type" => "job.started",
        "message" => "Started implementing #1.",
        "job_id" => job_id
      })

    :ok =
      Log.accept(worker.id, %{
        "at" => at.(6),
        "type" => "job.exited",
        "level" => "error",
        "message" => "Harness exited with status 137 (out of memory).",
        "job_id" => job_id
      })

    :ok = Log.record(worker.id, "worker.disconnected", :error, "Socket closed: timeout.")

    :ok =
      Log.record(
        worker.id,
        "worker.destroyed",
        :info,
        "Destroyed after 5 minutes without a heartbeat."
      )
  end

  @doc """
  What `14a`–`14f` draw, for `owner`: a fake account named `hz-main` whose catalogue prices three
  sizes in euros, a template with room (`hetzner-cx32`, four at most, two made), one full
  (`hetzner-cx22`, two of two), and one taken out of service (`gpu-bench`). **Sets the fake
  provider's catalogue**, which stays until `Forge.Provider.Fake.allow/0`.
  """
  def templates_fixture(owner) do
    Forge.Provider.Fake.offering([
      shape("cx22", 4, 2, "0.0060"),
      shape("cx32", 8, 4, "0.0110"),
      shape("ccx33", 32, 8, "0.1060")
    ])

    Forge.Provider.Fake.listing([
      snapshot("snap-412", "8rh57whmgk6m"),
      snapshot("snap-398", "aaaaaaaaaaaa"),
      snapshot("snap-377", nil)
    ])

    {:ok, hz} =
      Provisioning.create_credential(owner, %{
        name: "hz-main",
        provider: "fake",
        secret: %{"token" => "made-up"}
      })

    game = project_fixture(%{name: "slots"}) |> join!(owner)
    site = project_fixture(%{name: "pages"}) |> join!(owner)
    project_fixture(%{name: "idle-project"}) |> join!(owner)

    on = fn attrs -> Map.merge(%{provider_credential_id: hz.id}, attrs) end

    cx32 =
      template_fixture(
        owner,
        on.(%{
          name: "hetzner-cx32",
          size: "cx32",
          image: "snap-412",
          image_build: "8rh57whmgk6m",
          image_protocol: ForgeCore.WorkerProtocol.current(),
          max_workers: 4,
          idle_ms: 15 * 60_000
        }),
        [game]
      )

    cx22 =
      template_fixture(
        owner,
        on.(%{
          name: "hetzner-cx22",
          size: "cx22",
          image: "snap-398",
          image_build: "aaaaaaaaaaaa",
          image_protocol: ForgeCore.WorkerProtocol.current(),
          memory: 4 * 1024 * 1024 * 1024,
          cores: 2,
          max_workers: 2,
          idle_ms: 10 * 60_000,
          accepts: [:chat]
        }),
        [site]
      )

    gpu =
      template_fixture(
        owner,
        on.(%{
          name: "gpu-bench",
          size: "ccx33",
          image: "snap-377",
          memory: 32 * 1024 * 1024 * 1024,
          cores: 8,
          accepts: [:workflow]
        })
      )

    {_n, _} =
      Forge.Repo.update_all(from(t in Provisioning.Template, where: t.id == ^gpu.id),
        set: [
          failures: Provisioning.failure_limit(),
          last_error: "worker refused at join, protocol 6"
        ]
      )

    for template <- [cx32, cx32, cx22, cx22],
        do: machine_fixture(owner, Provisioning.Template.worker_attrs(template))

    %{credential: hz, templates: %{cx32: cx32, cx22: cx22, gpu: gpu}}
  end

  defp snapshot(id, build) do
    %{
      id: id,
      name: id,
      status: "available",
      build: build,
      protocol: build && ForgeCore.WorkerProtocol.current()
    }
  end

  defp shape(size, gib, cores, price) do
    %{
      size: size,
      memory: gib * 1024 * 1024 * 1024,
      cores: cores,
      price_hourly: Decimal.new(price),
      currency: "EUR"
    }
  end
end
