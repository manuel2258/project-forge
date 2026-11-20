defmodule ForgeWeb.UI.Attach do
  @moduledoc """
  The box a file is attached in, on every place a person writes something an agent will read
  (`docs/design/ui.md` § Attaching files, `docs/design/attachments.md`).

  **Draw it inside the form it belongs to.** A button opens the file picker (on a phone, the
  phone's own: camera and library included), a file dropped on the form is attached, and so is a
  copied image pasted into it. Each file is uploaded as it is chosen, to `UploadController`, and
  shows its name, size and progress and can be removed; **sending waits for the uploads still
  running**, and a file that failed is named as *not sent* while the rest go.

  The form carries what finished as hidden fields — `attachments[ids][]` with `attachments[names][]`
  beside them, the name as uploaded — and what failed as `attachments[failed][]`, read by
  `ForgeWeb.Attaching.batch/1`. They live in a container LiveView does not patch, so that a
  rejoin's form recovery sends them and a reconnect keeps the files that finished
  (`docs/design/ui.md` § A reconnect is not a reload). A reload, another device or navigating away
  starts the form over.

  The box checks what it can before any bytes go — a file over the limit, an eleventh file, a file
  past the room the pool had when the page was drawn (`room`) — which is a courtesy: the limits are
  counted where the bytes arrive (`Forge.Attachments`).
  """

  use Phoenix.Component
  use ForgeWeb, :verified_routes

  alias Forge.Attachments

  @doc """
  The names of the files that came with something a person wrote, each a link to that file's
  version (`docs/design/ui.md` § Attaching files): under a chat message, a note, an answer, the
  ticket's text and a document's version. **No thumbnail, gallery or preview.** A long name is cut
  on screen with the whole name in its title, markup in a name is text (HEEx escapes it), an
  `.svg` stays a download (the route serves it as one), a file withdrawn says *withdrawn* where its
  link was, and one whose upload failed says *not received*.

  `files` are `Forge.Attachments.entries/1`; `path` turns a live entry into the address of its
  version, which the caller knows (a ticket's, or a project chat's).
  """
  attr :files, :list, required: true
  attr :path, :any, required: true
  attr :class, :any, default: nil

  def names(assigns) do
    ~H"""
    <p :if={@files != []} class={["ui-attached", @class]} data-attached>
      <span class="ui-attached-label">Attached</span>
      <span :for={file <- @files} class="ui-attached-file" data-state={file.state}>
        <.link
          :if={file.state == :live}
          href={@path.(file)}
          class="ui-attached-link"
          title={file.original}
        >
          {file.file}
        </.link>
        <span :if={file.state == :withdrawn} class="ui-attached-name" title={file.original}>
          {file.file}<span class="ui-attached-state"> · withdrawn</span>
        </span>
        <span :if={file.state == :not_received} class="ui-attached-name" title={file.original}>
          {file.original}<span class="ui-attached-state"> · not received</span>
        </span>
      </span>
    </p>
    """
  end

  @doc """
  `id` is unique on the page; `project` is the project's name, which the upload route names; `room`
  is `Forge.Attachments.room/1` of the pool the files go into, or nil where it is not known yet
  (a ticket being made has an empty pool).
  """
  attr :id, :string, required: true
  attr :project, :string, required: true
  attr :room, :map, default: nil
  attr :label, :string, default: "Attach files"

  attr :form, :string,
    default: nil,
    doc: "the id of the form the box belongs to, when it is drawn outside it"

  def box(assigns) do
    limits = Attachments.limits()
    room = assigns.room || %{files: limits.pool_files, bytes: limits.pool_bytes}

    assigns =
      assigns
      |> assign(:url, ~p"/projects/#{assigns.project}/uploads")
      |> assign(:limits, limits)
      |> assign(:room, room)

    ~H"""
    <div
      id={@id}
      class="ui-attach"
      data-attach
      phx-hook=".Attach"
      data-url={@url}
      data-form={@form}
      data-max-bytes={@limits.file_bytes}
      data-max-files={@limits.per_act}
      data-pool-files={@limits.pool_files}
      data-pool-bytes={@limits.pool_bytes}
      data-room-files={@room.files}
      data-room-bytes={@room.bytes}
    >
      <label class="ui-attach-button">
        <span>{@label}</span>
        <input type="file" multiple class="ui-attach-input" aria-label={@label} />
      </label>
      <ul id={@id <> "-list"} class="ui-attach-list" data-attach-list phx-update="ignore"></ul>
      <div id={@id <> "-fields"} data-attach-fields phx-update="ignore" hidden></div>
      <p id={@id <> "-notsent"} class="ui-attach-notsent" data-attach-notsent phx-update="ignore"></p>
      <div id={@id <> "-refusals"} data-attach-refusals phx-update="ignore"></div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Attach">
      const UNITS = ["bytes", "KiB", "MiB", "GiB"]

      function size(bytes) {
        let n = bytes, unit = 0
        while (n >= 1024 && unit < UNITS.length - 1) { n /= 1024; unit++ }
        return unit === 0 ? `${n} bytes` : `${n.toFixed(n >= 10 ? 0 : 1)} ${UNITS[unit]}`
      }

      const pad = (n) => String(n).padStart(2, "0")

      export default {
        mounted() {
          this.url = this.el.dataset.url
          this.maxBytes = Number(this.el.dataset.maxBytes)
          this.maxFiles = Number(this.el.dataset.maxFiles)
          this.items = []
          this.pending = null
          this.submitted = false
          this.pastes = 0
          this.form = this.el.closest("form") || document.getElementById(this.el.dataset.form)
          this.list = this.el.querySelector("[data-attach-list]")
          this.fields = this.el.querySelector("[data-attach-fields]")
          this.notSent = this.el.querySelector("[data-attach-notsent]")
          this.refusals = this.el.querySelector("[data-attach-refusals]")
          this.input = this.el.querySelector("input[type=file]")

          this.input.addEventListener("change", () => {
            this.add([...this.input.files])
            this.input.value = ""
          })

          const hasFiles = (event) => [...(event.dataTransfer?.types || [])].includes("Files")
          this.form.addEventListener("dragover", (event) => { if (hasFiles(event)) event.preventDefault() })
          this.form.addEventListener("drop", (event) => {
            if (!hasFiles(event)) return
            event.preventDefault()
            this.add([...event.dataTransfer.files])
          })
          this.form.addEventListener("paste", (event) => {
            const files = [...(event.clipboardData?.files || [])]
            if (files.length === 0) return
            event.preventDefault()
            this.add(files.map((file) => this.named(file)))
          })

          // Before LiveView's own submit handler, which sees the form after this one has let it go.
          this.form.addEventListener("submit", (event) => this.submitting(event), true)
          this.handleEvent("attach:sent", () => this.sent())
        },

        // A pasted picture is called `image.png` by every browser, so two pastes would be one name.
        named(file) {
          if (!/^image\.[a-z0-9]+$/i.test(file.name)) return file
          const now = new Date()
          const ext = (file.name.split(".").pop() || "png").toLowerCase()
          const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-` +
            `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
          const suffix = this.pastes++ > 0 ? `-${this.pastes}` : ""
          return new File([file], `pasted-${stamp}${suffix}.${ext}`, { type: file.type })
        },

        add(files) {
          this.refusals.replaceChildren()

          for (const file of files) {
            const refusal = this.refuse(file)
            if (refusal) { this.refuse_note(refusal); continue }

            const item = { file, name: file.name, size: file.size, state: "uploading", id: null, xhr: null }
            item.li = this.row(item)
            this.items.push(item)
            this.upload(item)
          }

          this.render()
        },

        // What is known before any byte goes: the size of the file, how many there are, and the
        // room the pool had when the page was drawn.
        refuse(file) {
          const live = this.items.filter((item) => item.state !== "failed")
          const bytes = live.reduce((sum, item) => sum + item.size, 0)

          if (file.size > this.maxBytes)
            return `${file.name} is over the limit of ${size(this.maxBytes)} for one file.`
          if (live.length >= this.maxFiles)
            return `${file.name} was not attached: no more than ${this.maxFiles} files with one message or note.`
          if (live.length >= Number(this.el.dataset.roomFiles))
            return `${file.name} was not attached: it would pass the limit of ${this.el.dataset.poolFiles} files in all.`
          if (bytes + file.size > Number(this.el.dataset.roomBytes))
            return `${file.name} was not attached: it would pass the limit of ${size(Number(this.el.dataset.poolBytes))} in all.`
          return null
        },

        refuse_note(text) {
          const p = document.createElement("p")
          p.className = "ui-error-note"
          p.setAttribute("role", "alert")
          p.textContent = text
          this.refusals.append(p)
        },

        row(item) {
          const li = document.createElement("li")
          li.className = "ui-attach-row"

          const name = document.createElement("span")
          name.className = "ui-attach-name"
          name.textContent = item.name
          name.title = item.name

          const meta = document.createElement("span")
          meta.className = "ui-attach-meta"
          meta.textContent = size(item.size)

          const bar = document.createElement("progress")
          bar.max = 100
          bar.value = 0
          bar.className = "ui-attach-progress"

          const remove = document.createElement("button")
          remove.type = "button"
          remove.className = "ui-attach-remove"
          remove.textContent = "Remove"
          remove.setAttribute("aria-label", `Remove ${item.name}`)
          remove.addEventListener("click", () => this.remove(item))

          li.append(name, meta, bar, remove)
          item.bar = bar
          item.meta = meta
          this.list.append(li)
          return li
        },

        upload(item) {
          const xhr = new XMLHttpRequest()
          item.xhr = xhr
          xhr.open("POST", this.url)
          xhr.setRequestHeader("content-type", "application/octet-stream")
          xhr.setRequestHeader("x-csrf-token", document.querySelector("meta[name='csrf-token']")?.content || "")
          xhr.setRequestHeader("x-file-name", encodeURIComponent(item.name))

          xhr.upload.onprogress = (event) => {
            if (event.lengthComputable) item.bar.value = Math.round((event.loaded / event.total) * 100)
          }
          xhr.onload = () => {
            let body = {}
            try { body = JSON.parse(xhr.responseText) } catch (_) {}
            if (xhr.status === 200 && body.id) {
              item.id = body.id
              this.finish(item, "done")
            } else {
              const why = body.error?.limit ? `over the limit of ${body.error.limit}` : `the platform answered ${xhr.status}`
              this.finish(item, "failed", why)
            }
          }
          xhr.onerror = () => this.finish(item, "failed", "the connection was lost")
          xhr.onabort = () => {}
          xhr.send(item.file)
        },

        finish(item, state, why) {
          item.state = state
          item.xhr = null
          item.bar.value = 100
          item.meta.textContent = state === "done" ? size(item.size) : `${size(item.size)} · not sent: ${why}`
          item.li.classList.toggle("ui-attach-row--failed", state === "failed")
          this.render()
          if (this.pending && !this.items.some((i) => i.state === "uploading")) this.release()
        },

        // Removing is un-attaching, not a failure: a staged file is deleted, an upload in flight is
        // cut, and nobody is told it was ever there.
        remove(item) {
          if (item.xhr) { item.xhr.abort(); item.xhr = null }
          if (item.id) {
            fetch(`${this.url}/${item.id}`, {
              method: "DELETE",
              headers: { "x-csrf-token": document.querySelector("meta[name='csrf-token']")?.content || "" },
              keepalive: true
            }).catch(() => {})
          }
          item.li.remove()
          this.items = this.items.filter((i) => i !== item)
          this.render()
          if (this.pending && !this.items.some((i) => i.state === "uploading")) this.release()
        },

        // The fields the form sends, from what the items are now.
        render() {
          const inputs = []
          const hidden = (name, value) => {
            const input = document.createElement("input")
            input.type = "hidden"
            input.name = name
            input.value = value
            if (this.el.dataset.form) input.setAttribute("form", this.el.dataset.form)
            inputs.push(input)
          }
          for (const item of this.items) {
            if (item.state === "done") { hidden("attachments[ids][]", item.id); hidden("attachments[names][]", item.name) }
            if (item.state === "failed") hidden("attachments[failed][]", item.name)
          }
          this.fields.replaceChildren(...inputs)
          this.el.dispatchEvent(new CustomEvent("forge:attach", { bubbles: true, detail: { uploading: this.items.some((i) => i.state === "uploading") } }))
        },

        submitting(event) {
          if (this.items.some((item) => item.state === "uploading")) {
            event.preventDefault()
            event.stopPropagation()
            this.pending = event.submitter || true
            this.waiting(true)
          } else {
            this.submitted = this.items.length > 0
          }
        },

        waiting(on) {
          this.el.classList.toggle("ui-attach--waiting", on)
        },

        release() {
          const submitter = this.pending === true ? undefined : this.pending
          this.pending = null
          this.waiting(false)
          this.form.requestSubmit(submitter)
        },

        // The act went through: what was sent leaves the list, and what failed is named beside the
        // box as not sent, for as long as the form is.
        sent() {
          if (!this.submitted) return
          this.submitted = false
          const failed = this.items.filter((item) => item.state === "failed").map((item) => item.name)
          this.items = []
          this.list.replaceChildren()
          this.fields.replaceChildren()
          this.notSent.textContent = failed.length ? `Not sent: ${failed.join(", ")}` : ""
        }
      }
    </script>
    """
  end
end
