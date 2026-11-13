defmodule ForgeWeb.FileTypeTest do
  @moduledoc """
  What kind of file an artifact is (`docs/design/ui.md` § Artifact types): from its name and its
  kind, and never from its bytes.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ForgeWeb.FileType

  defp type(name, kind), do: FileType.of(%{name: name, kind: kind})

  describe "of/1" do
    test "a blob is what its extension says, whatever its case or its group" do
      assert type("package/app.apk", :blob) == :apk
      assert type("package/APP.APK", :blob) == :apk
      assert type("build.log", :blob) == :log
      assert type("notes.md", :blob) == :markdown
      assert type("results.csv", :blob) == :text
      assert type("report.json", :blob) == :code
      assert type("shots/home.png", :blob) == :image
      assert type("dist/site.tar.gz", :blob) == :archive
      assert type("package/app.aab", :blob) == :archive
    end

    # A commit, not a file: only the blob the engine records under that name.
    test "the changeset is its own type" do
      assert type("changeset", :blob) == :changeset
      assert type("changeset", :document) == :markdown
      assert type("package/changeset", :blob) == :file
    end

    test "a blob whose extension says nothing this knows is a file" do
      assert type("package/manifest", :blob) == :file
      assert type("core.dump", :blob) == :file
    end

    # A document is text by construction, so a name that says otherwise does not make it a
    # picture; only text, a log and code are told apart from Markdown.
    test "a document is Markdown unless its name says text, a log or code" do
      assert type("plan.md", :document) == :markdown
      assert type("plan", :document) == :markdown
      assert type("shot.png", :document) == :markdown
      assert type("app.apk", :document) == :markdown
      assert type("notes.txt", :document) == :text
      assert type("run.log", :document) == :log
      assert type("schema.json", :document) == :code
      assert type("deck", :presentation) == :markdown
    end
  end

  describe "download_type/1" do
    test "an Android app is its own type, so a phone hands it to the installer" do
      assert FileType.download_type("package/app.apk") ==
               "application/vnd.android.package-archive"

      assert FileType.download_type("APP.APK") == "application/vnd.android.package-archive"
    end

    test "anything else is bytes" do
      assert FileType.download_type("package/app.aab") == "application/octet-stream"
      assert FileType.download_type("shots/home.png") == "application/octet-stream"
      assert FileType.download_type("pkg") == "application/octet-stream"
    end
  end

  describe "raster?/2 and svg?/1" do
    test "a blob with a raster extension, in any case, and nothing else" do
      blob = %{blob_uri: "store:job/x/out-a/1"}

      for name <- ~w(a.png a.jpg a.jpeg a.gif a.webp a.avif shots/A.PNG),
          do: assert(FileType.raster?(name, blob), name)

      for name <- ~w(a.svg a.txt a.png.zip png a.apk),
          do: refute(FileType.raster?(name, blob), name)

      # A document is text, and a commit is not a file, whatever they are called.
      refute FileType.raster?("a.png", %{blob_uri: nil})
      refute FileType.raster?("changeset.png", %{blob_uri: "git:abc123"})
      assert FileType.image_type("a.JPEG") == "image/jpeg"
    end

    test "an SVG is known by its extension" do
      assert FileType.svg?("a.svg") and FileType.svg?("shots/B.SVG")
      refute FileType.svg?("a.png") or FileType.svg?("svg")
    end
  end

  @scope %{project_id: "p", project: "game", ticket: {"t", 1}, chat: nil}
  defp doc(content),
    do: %Forge.Artifacts.Version{content: content, inserted_at: DateTime.utc_now()}

  describe "render_document/3" do
    test "renders Markdown, and keeps text, a log and code as they were written" do
      assert {:html, html} = FileType.render_document("plan.md", doc("# Plan\n"), @scope)
      assert Phoenix.HTML.safe_to_string(html) =~ "<h1>Plan</h1>"
      assert {:html, _html} = FileType.render_document("plan", doc("# Plan\n"), @scope)

      for name <- ~w(notes.txt run.log schema.json) do
        assert FileType.render_document(name, doc("# a\nb\n"), @scope) == {:text, "# a\nb\n"}
      end
    end

    # Markdown is styled only inside `.doc` (`doc.css`, `ui.md` § Documents); text is a `pre`.
    test "draws Markdown in the document styles and text as preformatted" do
      draw = fn name ->
        body = FileType.render_document(name, doc("# a\n"), @scope)
        Floki.parse_fragment!(render_component(&FileType.document_body/1, body: body))
      end

      assert [_doc] = Floki.find(draw.("plan.md"), "div.doc h1")
      assert Floki.find(draw.("plan.md"), "pre") == []
      assert [_pre] = Floki.find(draw.("run.log"), "pre")
      assert Floki.find(draw.("run.log"), ".doc") == []
    end
  end

  describe "file_icon/1" do
    defp icon(name, kind, size \\ :row) do
      Floki.parse_fragment!(
        render_component(&FileType.file_icon/1, artifact: %{name: name, kind: kind}, size: size)
      )
    end

    # The tile's hue is keyed by the attribute, and the icon says its type in words, since an
    # icon alone says nothing to a screen reader.
    test "names its type for the stylesheet and for assistive technology" do
      for {name, kind, type, label} <- [
            {"plan.md", :document, "markdown", "Markdown"},
            {"notes.txt", :document, "text", "text"},
            {"build.log", :blob, "log", "log"},
            {"schema.json", :blob, "code", "code and data"},
            {"home.png", :blob, "image", "image"},
            {"site.zip", :blob, "archive", "archive"},
            {"app.apk", :blob, "apk", "Android app"},
            {"pkg", :blob, "file", "file"},
            {"changeset", :blob, "changeset", "changeset"}
          ] do
        [tile] = icon(name, kind)
        assert Floki.attribute(tile, "data-file-type") == [type]
        assert Floki.attribute(tile, "role") == ["img"]
        assert Floki.attribute(tile, "aria-label") == [label]
        # And as a tooltip, for a pointer that hovers it.
        assert Floki.attribute(tile, "title") == [label]
      end
    end

    # Each type its own glyph, as `ui.md` § Artifact types tables them — and only the glyph, so
    # a screen reader hears the tile's label and not the letters.
    test "draws each type's own glyph" do
      for {name, kind, glyph} <- [
            {"plan.md", :document, "md"},
            {"notes.txt", :document, "txt"},
            {"build.log", :blob, "log"},
            {"schema.json", :blob, "{}"},
            {"home.png", :blob, "img"},
            {"site.zip", :blob, "zip"},
            {"app.apk", :blob, "apk"},
            {"pkg", :blob, "file"},
            {"changeset", :blob, "±"}
          ] do
        assert [shown] = Floki.find(icon(name, kind), "[aria-hidden=true]"), name
        assert Floki.text(shown) == glyph, name
      end
    end

    # The handoff's `TypeIcon`: 26px in a row, 20 in a chip, and a word set smaller than a mark.
    test "is smaller in a chip than in a row" do
      assert icon("plan.md", :document) |> Floki.attribute("class") |> hd() =~ "size-[26px]"
      assert icon("plan.md", :document, :chip) |> Floki.attribute("class") |> hd() =~ "size-5"
      assert icon("plan.md", :document) |> Floki.attribute("class") |> hd() =~ "text-[9.5px]"
      assert icon("changeset", :blob) |> Floki.attribute("class") |> hd() =~ "text-[12px]"
    end

    # The Changes tab's `+n −m`: a changeset is a change, not a file.
    test "draws the changeset as a change" do
      assert Floki.text(icon("changeset", :blob)) == "±"
    end
  end
end
