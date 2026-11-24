defmodule ForgeCore.PromptPagesTest do
  @moduledoc """
  What a job and a conversation are told about pages (`docs/design/pages.md` § How a running job reaches the store),
  and the shape of `spec.pages` on its way to the worker.
  """

  use ExUnit.Case, async: true

  import ForgeCore.Fixtures

  alias ForgeCore.Job.Spec
  alias ForgeCore.Prompt

  @dir "/var/forge/jobs/job-1"

  defp page(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "form",
        "version" => 3,
        "files" => %{"index.html" => %{"hash" => String.duplicate("e", 64), "size" => 120}},
        "keys" => 12,
        "read_only" => nil,
        "by" => "an agent in authoring",
        "at" => "2026-11-22T10:00:00Z"
      },
      overrides
    )
  end

  defp chat_spec(overrides) do
    struct!(
      %Spec{
        job_id: "chat-1",
        kind: :chat,
        prompt: "Hello",
        branch: "chat/x",
        commit: String.duplicate("b", 40),
        preamble_hash: "sha256:y"
      },
      overrides
    )
  end

  describe "the manifest" do
    test "says nothing of pages where the workflow has none and the ticket has none" do
      manifest = Prompt.manifest(spec(), @dir)

      refute manifest =~ "## Pages"
      refute manifest =~ "FORGE_PAGES_URL"
      assert Prompt.manifest(%{spec() | pages: []}, @dir) == manifest
      assert Prompt.manifest(%{spec() | pages: nil}, @dir) == manifest
    end

    test "names a declared page as a directory with a required index.html" do
      manifest = Prompt.manifest(%{spec() | produces: ["plan.md", "form@"]}, @dir)

      assert manifest =~ "- `plan.md` -> `#{@dir}/out/plan.md` (carries the outcome)"
      assert manifest =~ "- `form@` -> a page: files in `#{@dir}/out/form/`"
      assert manifest =~ "**`index.html` is required**"
      assert manifest =~ "`forge-page.js` is reserved"
      refute manifest =~ "the diff of your commits"
      assert manifest =~ "## Pages"
      assert manifest =~ "`form` (no version yet)"
      assert manifest =~ "$FORGE_PAGES_URL"
      assert manifest =~ "$FORGE_GIT_TOKEN"
    end

    test "a declared page is optional where the state says so, and only then" do
      produces = ["plan.md", "form@"]

      assert Prompt.manifest(%{spec() | produces: produces}, @dir) =~ "`form@`"
      refute Prompt.manifest(%{spec() | produces: produces}, @dir) =~ "Optional:"

      optional = Prompt.manifest(%{spec() | produces: produces, optional: ["form"]}, @dir)
      assert optional =~ "so do not write one. Optional: you may finish without writing it"
    end

    test "lists the ticket's pages with their state, and says a read only one is" do
      pages = [page(), page(%{"name" => "wizard", "read_only" => "done", "keys" => 0})]
      manifest = Prompt.manifest(%{spec() | pages: pages}, @dir)

      assert manifest =~
               "- `form` — version 3, 1 files, 12 keys, written by an agent in authoring, 2026-11-22T10:00:00Z."

      assert manifest =~ "- `wizard` — version 3"
      assert manifest =~ "**Read only (done): its store takes no writes.**"

      refute manifest =~ "(no version yet)"
    end

    test "a state that rewrites a page the ticket has says so" do
      manifest =
        Prompt.manifest(%{spec() | produces: ["plan.md", "form@"], pages: [page()]}, @dir)

      assert manifest =~ "`form` (a new version of the above)"
      assert manifest =~ "the store is untouched by it"
    end

    test "tells how a write names the counter and what the answers mean" do
      manifest =
        %{spec() | pages: [page()]} |> Prompt.manifest(@dir) |> String.replace(~r/\s+/, " ")

      assert manifest =~ ~s("counter": 7)
      assert manifest =~ "`null` for a key you expect not to exist"
      assert manifest =~ "A write that omits the counter is refused"
      assert manifest =~ "**409 `changed`**"
      assert manifest =~ "**409 `read_only`**"
      assert manifest =~ "**413 `limit`**"
      assert manifest =~ "never instructions"
    end

    test "a continuation carries the section too" do
      prompt = Prompt.continuation(%{spec() | pages: [page()]}, @dir, "abc123")

      assert prompt =~ "## Pages"
    end
  end

  describe "a conversation" do
    test "is told of the ticket's pages and of none where there are none" do
      assert Prompt.chat_manifest(chat_spec(%{pages: [page()]}), @dir) =~
               "- `form` — version 3"

      refute Prompt.chat_manifest(chat_spec(%{pages: []}), @dir) =~ "## Pages"
      refute Prompt.chat_manifest(chat_spec(%{}), @dir) =~ "## Pages"
    end

    test "a step names the pages it must write apart from its documents" do
      step = %{
        "state" => "refining",
        "prompt" => "Do it.",
        "visit" => 1,
        "inputs" => [],
        "produces" => ["notes.md"],
        "pages" => ["form"],
        "optional" => [],
        "outcomes" => [%{"outcome" => "done", "to" => "next", "approve" => []}],
        "entered" => nil
      }

      manifest = Prompt.chat_manifest(chat_spec(%{step: step}), @dir)

      assert manifest =~ "Documents to write:\n- `notes.md` -> `#{@dir}/out/notes.md`"
      assert manifest =~ "Pages to write, each a directory with an `index.html`"
      assert manifest =~ "- `form` -> `#{@dir}/out/form/`"
      assert manifest =~ "## Pages"
      assert manifest =~ "`form` (no version yet)"

      only_page = Prompt.chat_manifest(chat_spec(%{step: %{step | "produces" => []}}), @dir)
      refute only_page =~ "Documents to write"
      assert only_page =~ "Pages to write"

      none =
        Prompt.chat_manifest(chat_spec(%{step: %{step | "produces" => [], "pages" => []}}), @dir)

      assert none =~ "This step declares no document to write."
    end

    test "a step spec read back has a page list, empty when it was written before pages" do
      step = %{"state" => "s", "prompt" => "p", "outcomes" => []}

      assert Spec.from_map(%{"job_id" => "j", "kind" => "chat", "step" => step}).step["pages"] ==
               []
    end
  end

  describe "the preambles and platform.md" do
    test "the conversation preamble says how to write a page and what a page cannot do" do
      flat = String.replace(Prompt.chat_preamble(), ~r/\s+/, " ")

      assert flat =~ "## Writing a page"
      assert flat =~ "`$FORGE_JOB/out/<name>/` holding `index.html`"
      assert flat =~ "`forge-page.js` is reserved"
      assert flat =~ "reaches nothing outside forge"
      assert flat =~ "$FORGE_PAGES_URL"
      assert flat =~ "read only"
    end

    test "platform.md has the Pages section the manifest points to" do
      platform = File.read!(Path.join(:code.priv_dir(:forge_core), "platform.md"))

      assert platform =~ "\n## Pages\n"
      assert platform =~ "`name@`"
      assert platform =~ "**409 `changed`**"
    end
  end

  describe "spec.pages" do
    test "survives a round trip through the row, in string keys, and is nil when never told" do
      spec = %{spec() | pages: [page()]}

      assert spec |> Spec.to_json() |> Spec.from_json() == {:ok, spec}
      assert Spec.from_map(%{"job_id" => "j"}).pages == nil
      assert Spec.from_map(%{"job_id" => "j", "pages" => []}).pages == []
    end

    test "fills what a platform left out, and reads atom keys as string ones" do
      [read] = Spec.from_map(%{"job_id" => "j", "pages" => [%{name: "form", version: 1}]}).pages

      assert read == %{
               "name" => "form",
               "version" => 1,
               "files" => %{},
               "keys" => 0,
               "read_only" => nil,
               "by" => nil,
               "at" => nil
             }
    end
  end
end
