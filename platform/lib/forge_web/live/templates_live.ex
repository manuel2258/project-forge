defmodule ForgeWeb.TemplatesLive do
  @moduledoc """
  Worker templates and the provider credentials they spend: what a machine is made from, how
  many of them there may be, and which projects may have them made.

  `docs/design/provisioning.md`, and `docs/design/ui.md` §§ Creating things and The affordance
  rule. Two things about this page that are not like the others:

  - **It is the first operator surface where a number is money that keeps accruing.** A
    template's `max_workers` is the only ceiling on machine spend, so it sits beside the price
    per hour rather than on a page of its own — raising one raises the other, and they should
    not be a navigation apart.
  - **It is per user, not per node.** A credential belongs to whoever entered it and a template
    to whoever made it, so this page shows one person's own and never anybody else's. That is
    `identity.md` § Credentials applied to infrastructure, and it is why this is not behind
    `node_admin`: a node admin has no more claim on a machine's bill than anyone else.

  The secret's shape comes from the driver (`Forge.Provider.credential_fields/1`), so this page
  asks for one token or a key pair without knowing which provider wants which.

  **The template form asks for nothing until an account is named.** A machine's sizes and images
  are read from the account that pays for them, so a provider that takes a credential shows only
  its name and its credential until one of the operator's is chosen — and the credential select
  offers no *none*, because a template naming no account could only fall back to the node's own
  token (`provisioning.md` § Where a machine comes from).
  """

  use ForgeWeb, :live_view

  import ForgeCore.Workflow.Resources, only: [gib: 1]

  alias Forge.{Projects, Provider, Provisioning, Workers}
  alias Forge.Provisioning.Template
  alias ForgeWeb.Format

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Templates") |> load() |> reset_forms()}
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user

    assign(socket,
      credentials: Provisioning.credentials(user),
      templates: Provisioning.templates(user),
      counts: Map.new(Provisioning.templates(user), &{&1.id, Provisioning.live_count(&1)}),
      assignments: Map.new(Provisioning.templates(user), &{&1.id, Provisioning.for_projects(&1)}),
      projects: Projects.list(user),
      providers: Provider.names(),
      current_build: Workers.current_build(),
      # **Only the providers that have a credential to give.** A driver whose
      # `credential_fields/0` is empty reaches its machines without an account — the local one
      # does — so offering it here is offering a form with nothing in it, which
      # `Credential.changeset/2` then refuses for having an empty secret. A local *template*
      # carries a null credential and that is the design (`provisioning.md` § Where a machine
      # comes from); a local *credential* is not a thing.
      credentialled: Enum.filter(Provider.names(), &(Provider.credential_fields(&1) != []))
    )
  end

  # What the provider will sell, asked of the driver with the credential the form has chosen
  # (`docs/design/provisioning.md` § Where a machine comes from). Picking one fills the size,
  # memory and cores rather than leaving an operator to copy three numbers off a price list and
  # get one of them wrong — and the platform still never parses the size it is handed back.
  #
  # An error is not fatal: a bad token or an API that is down leaves the fields to be typed,
  # which is what they were before this existed.
  #
  # **A provider that takes a credential is not asked anything until it has one.** A catalogue
  # is a question about an account, so with no account named there is nothing to ask and the
  # driver's refusal is not an error worth showing: the page used to mount on Hetzner with no
  # credential chosen and render *no Hetzner credential* twice in red before the operator had
  # done anything. `template_ready` is the same condition seen from the form's side — what
  # there is no point in filling in until an account pays for it.
  defp load_shapes(socket) do
    provider = socket.assigns.template_provider

    credential =
      Enum.find(socket.assigns.credentials, &(&1.id == socket.assigns.template_credential))

    socket = assign(socket, template_ready: credential != nil or not needs_credential?(provider))

    if socket.assigns.template_ready do
      secret =
        case credential && Provisioning.Credential.secret(credential) do
          {:ok, secret} -> secret
          _other -> nil
        end

      socket
      |> assign(catalogue(Provider.shapes(provider, secret), :shapes))
      |> assign(catalogue(Provider.images(provider, secret), :images))
    else
      assign(socket, shapes: [], shapes_error: nil, images: [], images_error: nil)
    end
  end

  # A provider whose driver declares no credential fields reaches its machines without an
  # account — the local one does — and a credential for it is a category that does not exist
  # (`docs/design/provisioning.md` § Whose account).
  defp needs_credential?(provider), do: Provider.credential_fields(provider) != []

  # The credential the template form should hold for this provider: the one chosen, when it is
  # that provider's, and otherwise that provider's first.
  #
  # **The chosen one is checked against the provider rather than trusted.** Changing the
  # provider arrives here with the *old* provider's credential still in the params, because the
  # select has not re-rendered yet; carrying it would fetch one account's catalogue under
  # another provider's driver and then be refused by `Template.changeset/2` on submit.
  defp credential_for(socket, provider, chosen) do
    for_provider = Enum.filter(socket.assigns.credentials, &(&1.provider == provider))

    case Enum.find(for_provider, &(&1.id == blank(chosen))) do
      nil -> for_provider |> List.first() |> then(&(&1 && &1.id))
      credential -> credential.id
    end
  end

  # Both catalogues fail the same way and for the same reasons — a bad token, an API that is
  # down — and neither is fatal: the fields stay typeable, which is what they were before a
  # catalogue existed. A page that refused to render because a provider was unreachable would
  # be a page you cannot use to fix the credential.
  defp catalogue({:ok, entries}, key), do: [{key, entries}, {:"#{key}_error", nil}]
  defp catalogue({:error, reason}, key), do: [{key, []}, {:"#{key}_error", inspect(reason)}]

  defp reset_forms(socket) do
    provider = List.first(socket.assigns.providers) || "local"
    # The credential form defaults to a provider that actually takes one, which is not
    # necessarily the one the template form defaults to.
    for_credential = List.first(socket.assigns.credentialled)
    # The first credential this provider has, because the select offers no way to choose none:
    # a machine is billed to an account, and a select showing one while the catalogue was
    # fetched with another would be a form lying about what it is about to spend.
    credential = credential_for(socket, provider, nil)

    socket
    |> assign(
      credential_form: to_form(%{"provider" => for_credential, "name" => ""}, as: :credential)
    )
    |> assign(credential_provider: for_credential)
    |> assign(credential_seq: (socket.assigns[:credential_seq] || 0) + 1)
    |> assign(
      template_form:
        to_form(
          %{
            "provider" => provider,
            "provider_credential_id" => credential || "",
            "name" => "",
            "max_workers" => "1"
          },
          as: :template
        )
    )
    |> assign(
      template_provider: provider,
      template_credential: credential,
      editing: nil,
      error: nil
    )
    |> load_shapes()
  end

  # The form filled from a template, for editing it. The two forms share one catalogue — it is
  # keyed on `template_provider` — so only one of them may be open at a time, which is why
  # `editing` hides the create form rather than sitting beside it.
  defp editing(socket, template) do
    params =
      %{
        "provider" => template.provider,
        "provider_credential_id" => template.provider_credential_id || "",
        "name" => template.name,
        "size" => template.size || "",
        "image" => template.image || "",
        "memory" => ForgeCore.Workflow.Resources.humanize(template.memory),
        "cores" => to_string(template.cores),
        "max_workers" => to_string(template.max_workers),
        "idle_minutes" => minutes(template.idle_ms)
      }
      |> Map.merge(ticked(template.accepts))

    socket
    |> assign(editing: template.id, error: nil)
    |> assign(template_form: to_form(params, as: :template))
    |> assign(template_provider: template.provider)
    |> assign(
      template_credential:
        credential_for(socket, template.provider, template.provider_credential_id)
    )
    |> load_shapes()
  end

  defp minutes(nil), do: ""
  defp minutes(ms), do: to_string(div(ms, 60_000))

  # Nil accepts is *any kind*, which is nothing ticked — the same reading `accepts/1` writes.
  defp ticked(nil), do: %{}
  defp ticked(accepts), do: Map.new(accepts, &{"accepts_#{&1}", "true"})

  @impl true
  # **Only the name and the provider are kept.** A `phx-change` form sends every field on every
  # keystroke, so what arrives here includes whatever has been typed into the secret, and
  # assigning it whole put the token in this LiveView's state and — because `<.input>` renders a
  # password field's value like any other — back into the page. The secret inputs are
  # `phx-update="ignore"`, so the server rendering them empty does not wipe what was typed.
  def handle_event("credential-provider", %{"credential" => params}, socket) do
    {:noreply,
     socket
     |> assign(credential_provider: params["provider"])
     |> assign(credential_form: to_form(Map.take(params, ["name", "provider"]), as: :credential))}
  end

  def handle_event("add-credential", %{"credential" => params}, socket) do
    fields = Provider.credential_fields(params["provider"])
    secret = Map.new(fields, &{&1.key, String.trim(params[&1.key] || "")})

    attrs = %{
      name: String.trim(params["name"] || ""),
      provider: params["provider"],
      secret: secret
    }

    case Provisioning.create_credential(socket.assigns.current_scope.user, attrs) do
      {:ok, _credential} -> {:noreply, socket |> load() |> reset_forms()}
      {:error, changeset} -> {:noreply, assign(socket, error: errors(changeset))}
    end
  end

  def handle_event("delete-credential", %{"id" => id}, socket) do
    Provisioning.delete_credential(socket.assigns.current_scope.user, id)
    {:noreply, socket |> load() |> refresh_credential() |> assign(error: nil)}
  end

  def handle_event("template-provider", %{"template" => params}, socket) do
    provider = params["provider"]
    credential = credential_for(socket, provider, params["provider_credential_id"])

    params =
      params
      |> fill_from_shape(socket.assigns.shapes, socket.assigns.template_form.params["size"])
      |> Map.put("provider_credential_id", credential || "")

    {:noreply,
     socket
     |> assign(template_provider: provider)
     |> assign(template_credential: credential)
     |> assign(template_form: to_form(params, as: :template))
     |> load_shapes()}
  end

  def handle_event("add-template", %{"template" => params}, socket) do
    attrs = params |> template_attrs() |> labelled(socket.assigns.images)

    with :ok <- enough_memory(attrs),
         {:ok, _template} <-
           Provisioning.create_template(socket.assigns.current_scope.user, attrs) do
      {:noreply, socket |> load() |> reset_forms()}
    else
      {:error, message} when is_binary(message) -> {:noreply, assign(socket, error: message)}
      {:error, changeset} -> {:noreply, assign(socket, error: errors(changeset))}
    end
  end

  # The id is the client's, so the template is read scoped to the caller before anything is
  # filled in from it — `identity.md` § Sequencing records this as the shape these holes keep
  # taking.
  def handle_event("edit-template", %{"id" => id}, socket) do
    case Provisioning.template(socket.assigns.current_scope.user, id) do
      nil -> {:noreply, socket}
      template -> {:noreply, editing(socket, template)}
    end
  end

  def handle_event("cancel-edit", _params, socket), do: {:noreply, reset_forms(socket)}

  # **`Provisioning.update_template/3` is the guard**: it reads the template scoped to the
  # caller and pins the owner, so the id this sends is checked where the write is. `editing` is
  # server state, set only by `edit-template` above after its own scoped read, so from this page
  # the context's check never refuses anything — it is there for the day somebody sets `editing`
  # from params, and it is tested at the context rather than here, where no test could fail.
  def handle_event("save-template", %{"template" => params}, socket) do
    user = socket.assigns.current_scope.user

    attrs = params |> template_attrs() |> labelled(socket.assigns.images)

    with :ok <- enough_memory(attrs),
         {:ok, _template} <- Provisioning.update_template(user, socket.assigns.editing, attrs) do
      {:noreply, socket |> load() |> reset_forms()}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, error: message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, error: errors(changeset))}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  # **Editing does not do this**, and that is the rule rather than an omission: a rename is not
  # a fix, and a template that earns three more tries every time somebody touches it is the
  # loop this counter exists to stop (`provisioning.md` § A template that cannot make a working
  # machine is taken out of service).
  def handle_event("enable-template", %{"id" => id}, socket) do
    case Provisioning.enable(socket.assigns.current_scope.user, id) do
      {:ok, _template} -> {:noreply, socket |> load() |> assign(error: nil)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("delete-template", %{"id" => id}, socket) do
    Provisioning.delete_template(socket.assigns.current_scope.user, id)
    {:noreply, socket |> load() |> assign(error: nil)}
  end

  def handle_event("assign", %{"template" => id, "project" => project_id}, socket) do
    case Provisioning.assign(socket.assigns.current_scope.user, id, project_id) do
      {:ok, _} -> {:noreply, socket |> load() |> assign(error: nil)}
      {:error, :not_a_member} -> {:noreply, assign(socket, error: "you are not in that project")}
      {:error, _reason} -> {:noreply, assign(socket, error: "could not assign it")}
    end
  end

  def handle_event("unassign", %{"template" => id, "project" => project_id}, socket) do
    Provisioning.unassign(socket.assigns.current_scope.user, id, project_id)
    {:noreply, socket |> load() |> assign(error: nil)}
  end

  # The credential the template form holds may have just been the one removed, and a select
  # offering a row that no longer exists would create a template against nothing. Re-resolving
  # is not the same as resetting the form: whatever was typed into it stays.
  defp refresh_credential(socket) do
    credential =
      credential_for(socket, socket.assigns.template_provider, socket.assigns.template_credential)

    params =
      Map.put(socket.assigns.template_form.params, "provider_credential_id", credential || "")

    socket
    |> assign(template_credential: credential)
    |> assign(template_form: to_form(params, as: :template))
    |> load_shapes()
  end

  # Choosing a size fills the two numbers that go with it. Only when the *size* changed, so an
  # operator who then edits the memory by hand keeps their edit — a form that overwrote it on
  # every keystroke would be a form that cannot be corrected.
  #
  # **`was` is what makes that true, and for a while nothing did.** The clause only asked
  # whether the size in the params matched a shape, which every change event carries once a
  # size is chosen, so picking `cpx31` and then touching the image select wrote the shape's
  # memory back over whatever had been typed. `phx-change` fires on the whole form, not on the
  # field that moved: the previous value is the only thing that says the size is what changed.
  defp fill_from_shape(params, shapes, was) do
    size = params["size"]

    case Enum.find(shapes, &(&1.size == size and size not in [nil, ""] and size != was)) do
      nil ->
        params

      shape ->
        # The unit a person would type, not the byte count. The field is labelled `8GiB` and
        # filling it with `8589934592` made the form argue with its own label — and, until
        # `parse_bytes/1` took a bare numeric string, refuse the very value it had written.
        Map.merge(params, %{
          "memory" => ForgeCore.Workflow.Resources.humanize(shape.memory),
          "cores" => to_string(shape.cores)
        })
    end
  end

  # Blank is nil and not zero, throughout: a field left empty means *nothing said*, and reading
  # it as a number would give a template no memory or an idle period of no time at all.
  defp template_attrs(params) do
    %{
      name: String.trim(params["name"] || ""),
      provider: params["provider"],
      provider_credential_id: blank(params["provider_credential_id"]),
      size: blank(params["size"]),
      image: blank(params["image"]),
      memory: bytes(params["memory"]),
      cores: number(params["cores"]),
      max_workers: number(params["max_workers"]),
      idle_ms: minutes_to_ms(params["idle_minutes"]),
      accepts: accepts(params)
    }
  end

  # **What the chosen snapshot carries, from the listing this page already holds** — never from the
  # form, whose params are the client's (`docs/design/provisioning.md` § A snapshot that speaks the
  # wrong protocol). An image the listing does not have — typed by hand for a provider that lists
  # none, or gone since the page loaded — is unlabelled, and `Template.changeset/2` keeps what is
  # already known about an image that did not change.
  # **And for `latest`, what the snapshot now marked carries**, so the page says something
  # sensible the moment the template is saved rather than after its first machine. A seed and not
  # the authority: `Forge.Workers` re-asks the driver at every create, so a stale one shows a
  # wrong build on this page until then and never makes a machine from the wrong snapshot
  # (`docs/design/provisioning.md` § Where a machine comes from).
  defp labelled(attrs, images) do
    image =
      if Template.latest?(attrs),
        do: Provisioning.current_image(images),
        else: Enum.find(images, &(&1.id == attrs.image))

    Map.merge(attrs, %{
      # Only for `latest`. A snapshot id resolves to itself and `Template.changeset/2` is what
      # says so, so this page does not carry a second copy of that rule; nil here is *nothing
      # new*, which a save of an unchanged image keeps rather than forgets.
      resolved_image: if(Template.latest?(attrs), do: image && image.id),
      image_build: image && image[:build],
      image_protocol: image && image[:protocol]
    })
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(value), do: String.trim(value)

  defp number(value) do
    case Integer.parse(to_string(value)) do
      {n, _rest} -> n
      :error -> nil
    end
  end

  defp minutes_to_ms(value) do
    case number(value) do
      nil -> nil
      minutes -> minutes * 60_000
    end
  end

  # **A machine smaller than the least one job can run in makes nothing anybody can use**, so it is
  # refused here, by name, before anything is saved (`docs/design/workflow-grammar-v1.md`
  # § Resources). On the page and not the schema: what a template may not be is decided by the
  # job it would hold, and a job below the minimum is refused where its row is made — a template
  # of eight thousand bytes that some other caller made holds no job, which the gate already
  # says. A figure nobody typed is the changeset's to call blank.
  defp enough_memory(%{memory: bytes}) when is_integer(bytes) do
    if ForgeCore.Workflow.Resources.enough_memory?(bytes),
      do: :ok,
      else: {:error, ForgeCore.Workflow.Resources.memory_refused()}
  end

  defp enough_memory(_attrs), do: :ok

  # The same units the grammar accepts, so an operator who writes `8GiB` in a workflow can write
  # it here (`docs/design/workflow-grammar-v1.md` § Resources).
  defp bytes(value) do
    case ForgeCore.Workflow.Resources.parse_bytes(blank(value) || "") do
      {:ok, bytes} -> bytes
      _other -> nil
    end
  end

  # Nothing ticked is nil rather than an empty list: "takes anything", the same reading a worker
  # that reported no kinds gets.
  #
  # **Returning `[]` here is an equivalent mutant and must not have a test written for it.**
  # `Workers.accepts?/2` and `Provisioning.holds?/2` both answer `true` for an empty list as
  # well as for nil, on purpose, so the two are indistinguishable by every path that reads
  # them. Nil is chosen because it is what the column means elsewhere, not because anything
  # behaves differently.
  defp accepts(params) do
    case Enum.filter(Forge.Jobs.Job.kinds(), &(params["accepts_#{&1}"] == "true")) do
      [] -> nil
      kinds -> kinds
    end
  end

  defp errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp shape_label(shape) do
    "#{shape.size} — #{gib(shape.memory)}, #{shape.cores} cores" <> price(shape)
  end

  defp price(%{price_hourly: nil}), do: ""
  defp price(%{price_hourly: hourly}), do: ", #{hourly}/h"
  defp price(_shape), do: ""

  # The empty option of a select, worded for what leaving it empty does. A provider that cannot
  # make a machine without the field gets a prompt, because *the node's default* would be a
  # promise `Template.changeset/2` then refuses to keep.
  defp blank_choice(required, field, otherwise),
    do: {if(field in required, do: "choose one", else: otherwise), ""}

  # A snapshot as the image select offers it: its name, then what it carries, and whether it is
  # the one `latest` resolves to — so choosing the mark and choosing an id are the same informed
  # choice (`docs/design/provisioning.md` § Where a machine comes from).
  defp image_label(image, current_build) do
    "#{image.name || image.id} · #{carries(image[:build], image[:protocol], current_build)}" <>
      if image[:current], do: " · carries latest", else: ""
  end

  # The mark itself, offered beside the snapshots: a template naming it is made from whichever
  # one carries it at the time, so the option says which that is today. *None marked yet* rather
  # than no option at all, because a provider whose account has never been built for is exactly
  # where a person needs to be told what the word would mean.
  # A row's identifiers: the provider, the size and the image it names. A template naming `latest`
  # names no snapshot, so the one it is resolved to goes after it — the row would otherwise say
  # nothing about which build its next machine comes from.
  defp names(%Template{} = template) do
    [template.provider, template.size, template.image, followed(template)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp followed(%Template{resolved_image: resolved} = template) when is_binary(resolved) do
    if Template.latest?(template), do: "now #{resolved}"
  end

  defp followed(_template), do: nil

  defp latest_label(nil), do: "#{Template.latest()} · none marked yet"
  defp latest_label(current), do: "#{Template.latest()} · #{current.name || current.id}"

  # What a snapshot carries, in the words the template row and the image select share: its build
  # against the one this platform ships with, and its protocol — or *unlabelled*, for a snapshot
  # from before the labels existed, which cannot be identified after the fact.
  defp carries(nil, nil, _current_build), do: "unlabelled"

  defp carries(build, protocol, current_build) do
    [build(build, current_build), protocol && "protocol #{protocol}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # A snapshot whose label names no build is *unknown*, and draws nothing rather than a hint. Not
  # the workers page's reading of a machine that joined with none — which is "other build", since
  # a release outside the Nix store cannot be the one this platform ships with.
  defp build(nil, _current_build), do: nil

  defp build(build, current_build) do
    case Format.build_hint(build, current_build) do
      nil -> "build #{build}"
      hint -> "build #{build} #{hint}"
    end
  end

  # A template whose snapshot this platform would refuse makes nothing, and says so here before
  # any job asks — its failures only begin once one does. Once they have, the failures line
  # carries the same sentence as its last error, and it is not said twice.
  defp refusal(template) do
    case Provisioning.image_refusal(template) do
      nil -> nil
      same when same == template.last_error -> nil
      sentence -> sentence
    end
  end

  defp kinds(nil), do: "any kind"
  defp kinds([]), do: "any kind"
  defp kinds(accepts), do: Enum.map_join(accepts, ", ", &to_string/1)

  attr :form, :any, required: true
  attr :credentials, :list, required: true
  attr :provider, :string, required: true
  attr :credential, :string, default: nil
  attr :providers, :list, required: true
  attr :shapes, :list, required: true
  attr :images, :list, required: true
  attr :shapes_error, :string, default: nil
  attr :images_error, :string, default: nil
  attr :ready, :boolean, required: true
  attr :required, :list, required: true
  attr :submit, :string, required: true
  attr :current_build, :string, default: nil
  slot :beside

  # What a template is made of: the fields for the form that makes one and the form that edits
  # one. One definition rather than two, because a second would be a copy of eleven fields that
  # drifts the first time one of them changes — and these are the fields most likely to change,
  # since every one of them is something a driver taught the platform to ask for.
  defp template_fields(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end gap-3">
      <.input field={@form[:name]} type="text" label="Name" autocomplete="off" />
      <.input
        field={@form[:provider]}
        type="select"
        label="Provider"
        options={@providers}
      />
      <%!-- Only this provider's credentials, and no way to choose none: what a template
                creates is billed to an account, and a template naming no account could only
                fall back to the node's own token, which is the thing per-user credentials
                replaced. A provider that reaches its machines without an account has no
                select at all (`provisioning.md` § Whose account). --%>
      <.input
        :if={@credential}
        field={@form[:provider_credential_id]}
        type="select"
        label="Credential"
        options={for c <- @credentials, c.provider == @provider, do: {c.name, c.id}}
      />
    </div>

    <p :if={not @ready} class="text-sm opacity-60">
      Add a {@provider} credential above. Its machine sizes and images are read from
      the account that pays for them, so there is nothing to fill in until there is one.
    </p>

    <p :if={@shapes_error} class="text-sm text-error">
      could not read {@provider}&#39;s machine sizes: {@shapes_error}
    </p>

    <p :if={@images_error} class="text-sm text-error">
      could not read {@provider}&#39;s images: {@images_error}
    </p>

    <%!-- `contents`, so the rest of the form is one thing to show or hide while its rows
              stay rows of the form itself. --%>
    <div :if={@ready} class="contents">
      <div class="flex flex-wrap items-end gap-3">
        <%!-- The driver's own catalogue, so an operator picks a machine that exists rather
                  than typing a name that does not. Free text when the provider sells no named
                  shapes, which is the local one. --%>
        <%!-- The blank choice says what blank does: *custom* where the driver takes a template
                  with no size, and *choose one* where it refuses one
                  (`Forge.Provider.required_template_fields/1`). --%>
        <.input
          :if={Enum.any?(@shapes, & &1.size)}
          field={@form[:size]}
          type="select"
          label="Size"
          options={
            [blank_choice(@required, :size, "custom")] ++
              for s <- @shapes, s.size, do: {shape_label(s), s.size}
          }
        />
        <.input
          :if={not Enum.any?(@shapes, & &1.size)}
          field={@form[:size]}
          type="text"
          label="Size"
          autocomplete="off"
        />
      </div>

      <div class="flex flex-wrap items-end gap-3">
        <%!-- The snapshots this credential can see. Hetzner has no image upload, so these
                  are ones the operator made by hand; the platform offers what is there and
                  never makes one. Free text when the provider lists none, so a node can still
                  name a path it has. --%>
        <.input
          :if={@images != []}
          field={@form[:image]}
          type="select"
          label="Image"
          options={
            [
              blank_choice(@required, :image, "the node's default"),
              {latest_label(Provisioning.current_image(@images)), Template.latest()}
            ] ++ for(i <- @images, do: {image_label(i, @current_build), i.id})
          }
        />
        <.input
          :if={@images == []}
          field={@form[:image]}
          type="text"
          label="Image"
          autocomplete="off"
        />
        <.input field={@form[:memory]} type="text" label="Memory (e.g. 8GiB)" />
        <.input field={@form[:cores]} type="number" label="Cores" />
        <.input field={@form[:max_workers]} type="number" label="Max machines" />
        <.input field={@form[:idle_minutes]} type="number" label="Idle minutes" />
      </div>

      <fieldset class="flex flex-wrap items-center gap-4">
        <legend class="text-sm opacity-60">Takes — nothing ticked means any kind</legend>
        <%!-- **Checked from the form's own params**, or editing a template that takes only
              workflow jobs would render the boxes empty and save it as taking any kind. --%>
        <label :for={kind <- Forge.Jobs.Job.kinds()} class="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            name={"template[accepts_#{kind}]"}
            value="true"
            checked={@form.params["accepts_#{kind}"] == "true"}
          />
          {kind}
        </label>
      </fieldset>

      <button
        type="submit"
        class="h-[52px] self-start rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
      >
        {@submit}
      </button>
    </div>

    <%!-- Outside the part that hides. A template whose provider has no credential shows no
          fields at all, and a form you cannot leave is worse than one you cannot fill in. --%>
    {render_slot(@beside)}
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      capacity={@capacity}
      active={:workers}
      measure="60rem"
    >
      <header class="flex flex-wrap items-baseline gap-x-4 gap-y-2">
        <h1 class="text-2xl font-semibold -tracking-[.025em]">Templates</h1>
        <.link navigate={~p"/workers"} class="ml-auto text-sm text-primary hover:underline">
          Machines ›
        </.link>
      </header>

      <p class="mt-2 text-sm/[1.55] opacity-60">
        A template is how a machine gets made, not what it is afterwards: its values are copied
        onto a machine at creation, so editing one never changes a machine that already exists.
        A project makes machines from the templates assigned to it and from nothing else.
      </p>

      <p :if={@error} class="mt-4 text-sm text-error">{@error}</p>

      <h2 class="mt-10 text-lg font-semibold">Provider credentials</h2>
      <p class="mt-1 text-sm/[1.55] opacity-60">
        Yours, and nobody else's. A machine made from a template is billed to the account behind
        the credential that template names.
      </p>

      <ul class="mt-4 flex flex-col gap-2">
        <li
          :for={credential <- @credentials}
          class="flex min-h-[52px] items-center gap-4 rounded-field border border-base-300 px-4"
        >
          <span class="text-sm font-medium">{credential.name}</span>
          <span class="font-mono text-[12.5px] opacity-60">{credential.provider}</span>
          <button
            type="button"
            phx-click="delete-credential"
            phx-value-id={credential.id}
            data-confirm={"Remove #{credential.name}? Templates that name it stop being able to create."}
            class="ml-auto min-h-[46px] text-sm text-error hover:underline"
          >
            Remove
          </button>
        </li>
        <li :if={@credentials == []} class="text-sm opacity-60">None yet.</li>
      </ul>

      <p :if={@credentialled == []} class="mt-4 text-sm opacity-60">
        No provider configured on this node needs one. A local machine is made by this host and
        there is no account to reach.
      </p>

      <.form
        :if={@credentialled != []}
        for={@credential_form}
        id="credential-form"
        phx-change="credential-provider"
        phx-submit="add-credential"
        class="mt-4 flex flex-wrap items-end gap-3"
      >
        <.input field={@credential_form[:name]} type="text" label="Name" autocomplete="off" />
        <.input
          field={@credential_form[:provider]}
          type="select"
          label="Provider"
          options={@credentialled}
        />
        <%!-- Written out rather than `<.input>`, which renders a field's value into the page.
              The id carries the provider and a sequence: a different provider's fields, or the
              form after a successful add, are new elements rather than ignored old ones. --%>
        <div
          :for={field <- Provider.credential_fields(@credential_provider)}
          class="fieldset mb-2"
          id={"credential-secret-#{@credential_provider}-#{field.key}-#{@credential_seq}"}
          phx-update="ignore"
        >
          <label for={"credential-secret-input-#{field.key}-#{@credential_seq}"}>
            <span class="label mb-1">{field.label}</span>
            <input
              type="password"
              name={"credential[#{field.key}]"}
              id={"credential-secret-input-#{field.key}-#{@credential_seq}"}
              autocomplete="off"
              class="w-full input"
            />
          </label>
        </div>
        <button
          type="submit"
          class="h-[52px] rounded-field bg-base-content px-4 text-sm font-medium text-base-100"
        >
          Add
        </button>
      </.form>

      <h2 class="mt-12 text-lg font-semibold">Templates</h2>

      <ul class="mt-4 flex flex-col gap-3">
        <li
          :for={template <- @templates}
          class="rounded-box border border-base-300 p-4"
          id={"template-#{template.id}"}
        >
          <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
            <span class="text-sm font-medium">{template.name}</span>
            <%!-- A flag, beside the identifiers and never instead of them: `ui.md` § The three
                  axes. It is the only thing on this page that is a state rather than a value. --%>
            <span
              :if={Provisioning.disabled?(template)}
              class="bg-error px-[5px] py-[1px] font-mono text-[11px] tracking-[.14em] uppercase text-base-100"
            >
              Disabled
            </span>
            <span class="font-mono text-[12.5px] opacity-60">
              {names(template)}
            </span>
            <%!-- What the snapshot carries, beside it: from its labels, or learnt from a machine
                  refused at join (`provisioning.md` § A snapshot that speaks the wrong
                  protocol). A template naming no image boots the driver's default. --%>
            <span
              :if={template.image || template.image_protocol}
              class="font-mono text-[12.5px] opacity-60"
            >
              {carries(template.image_build, template.image_protocol, @current_build)}
            </span>
            <span class="font-mono text-[12.5px] opacity-60">
              {gib(template.memory)} · {template.cores} cores · {kinds(template.accepts)}
            </span>
            <span class="font-mono text-[12.5px] opacity-60">
              {Map.get(@counts, template.id, 0)} of {template.max_workers} made
            </span>
            <div class="ml-auto flex items-baseline gap-4">
              <button
                :if={Provisioning.disabled?(template)}
                type="button"
                phx-click="enable-template"
                phx-value-id={template.id}
                class="min-h-[46px] text-sm text-primary hover:underline"
              >
                Enable
              </button>
              <button
                :if={is_nil(@editing)}
                type="button"
                phx-click="edit-template"
                phx-value-id={template.id}
                class="min-h-[46px] text-sm text-primary hover:underline"
              >
                Edit
              </button>
              <button
                type="button"
                phx-click="delete-template"
                phx-value-id={template.id}
                data-confirm={"Remove #{template.name}? Machines already made from it keep running."}
                class="min-h-[46px] text-sm text-error hover:underline"
              >
                Remove
              </button>
            </div>
          </div>

          <%!-- What went wrong, where the thing that went wrong is. A count below the limit is
                worth showing too: it is the warning before the template stops being used. --%>
          <p :if={refusal(template)} class="mt-2 text-sm/[1.55] text-error">
            {refusal(template)}: no machine is made from it until it names another
          </p>

          <p :if={template.failures > 0} class="mt-2 text-sm/[1.55] text-error">
            {template.failures} failed {if template.failures == 1, do: "attempt", else: "attempts"}
            <span :if={Provisioning.disabled?(template)}>— it is out of service until you enable it</span>
            <span :if={template.last_error}>: {template.last_error}</span>
          </p>

          <.form
            :if={@editing == template.id}
            for={@template_form}
            id={"edit-template-#{template.id}"}
            phx-change="template-provider"
            phx-submit="save-template"
            class="mt-3 flex flex-col gap-4 rounded-box border border-base-300 p-4"
          >
            <.template_fields
              form={@template_form}
              credentials={@credentials}
              provider={@template_provider}
              credential={@template_credential}
              providers={@providers}
              shapes={@shapes}
              images={@images}
              shapes_error={@shapes_error}
              images_error={@images_error}
              ready={@template_ready}
              required={Provider.required_template_fields(@template_provider)}
              submit="Save it"
              current_build={@current_build}
            >
              <:beside>
                <button
                  type="button"
                  phx-click="cancel-edit"
                  class="min-h-[46px] self-start text-sm text-primary hover:underline"
                >
                  Cancel
                </button>
              </:beside>
            </.template_fields>
          </.form>

          <div class="mt-3 flex flex-wrap items-center gap-2">
            <span class="text-sm opacity-60">Projects:</span>
            <span
              :for={project <- Map.get(@assignments, template.id, [])}
              class="flex items-center gap-1 rounded-field border border-base-300 pl-3 text-sm"
            >
              {project.name}
              <button
                type="button"
                phx-click="unassign"
                phx-value-template={template.id}
                phx-value-project={project.id}
                class="min-h-[46px] min-w-[46px] opacity-60 hover:opacity-100"
                aria-label={"Unassign #{project.name}"}
              >
                ×
              </button>
            </span>
            <span
              :if={Map.get(@assignments, template.id, []) == []}
              class="text-sm opacity-60"
            >
              none — this template is never used
            </span>

            <form phx-submit="assign" class="ml-auto flex items-center gap-2">
              <input type="hidden" name="template" value={template.id} />
              <select
                name="project"
                class="h-[46px] rounded-field border border-base-300 bg-base-100 px-2 text-sm"
              >
                <option :for={project <- @projects} value={project.id}>{project.name}</option>
              </select>
              <button type="submit" class="min-h-[46px] text-sm text-primary hover:underline">
                Assign
              </button>
            </form>
          </div>
        </li>
        <%!-- The empty state is the feature, not decoration: with no node fallback this is
              the whole reason a new node runs nothing (`provisioning.md` § Whose account). --%>
        <li :if={@templates == []} class="text-sm opacity-60">
          None yet, so nothing runs. A project makes machines from the templates assigned to it,
          and there is no fallback to the node's own settings.
        </li>
      </ul>

      <%!-- Creating one, and only while nothing is being edited: both forms are filled from
            `@template_form` and read one catalogue, so two open at once would be two sets of
            the same field ids fighting over the same state. --%>
      <.form
        :if={is_nil(@editing)}
        for={@template_form}
        id="template-form"
        phx-change="template-provider"
        phx-submit="add-template"
        class="mt-6 flex flex-col gap-4 rounded-box border border-base-300 p-4"
      >
        <.template_fields
          form={@template_form}
          credentials={@credentials}
          provider={@template_provider}
          credential={@template_credential}
          providers={@providers}
          shapes={@shapes}
          images={@images}
          shapes_error={@shapes_error}
          images_error={@images_error}
          ready={@template_ready}
          required={Provider.required_template_fields(@template_provider)}
          submit="Create it"
          current_build={@current_build}
        />
      </.form>
    </Layouts.app>
    """
  end
end
