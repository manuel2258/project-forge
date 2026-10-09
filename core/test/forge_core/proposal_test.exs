defmodule ForgeCore.ProposalTest do
  use ExUnit.Case, async: true

  alias ForgeCore.{Error, Proposal}

  describe "parse/1" do
    test "reads the H1 as the title and the rest as the body" do
      {:ok, proposal} =
        Proposal.parse(
          "# Extract the score table\n\nThe plan assumes a module that is not there."
        )

      assert proposal.title == "Extract the score table"
      assert proposal.body == "The plan assumes a module that is not there."
    end

    test "keeps the text it was given verbatim, so a proposal can be shown as written" do
      raw = "# Title\n\nBody with  odd   spacing.\n"
      {:ok, proposal} = Proposal.parse(raw)

      assert proposal.raw == raw
    end

    test "skips leading blank lines before the heading" do
      {:ok, proposal} = Proposal.parse("\n\n   \n# Title\n\nBody.")

      assert proposal.title == "Title"
    end

    test "accepts the indentation and closing hashes CommonMark allows" do
      {:ok, proposal} = Proposal.parse("   # Title ###\n\nBody.")

      assert proposal.title == "Title"
    end

    test "refuses a body that does not start with a heading" do
      assert {:error, [%Error{path: "title", message: message}]} =
               Proposal.parse("Just some prose about a thing.")

      assert message =~ "level-one heading"
    end

    # Front matter is what a *document* starts with, and a proposal is not one: the one key it
    # may hold is the ticket type it suggests. Written as its own case because the failure it
    # guards against is an agent reusing the document habit — an `outcome` here would be read as
    # nothing, and is refused and shown rather than silently ignored.
    test "refuses front matter holding anything but the type" do
      assert {:error, [%Error{path: "front_matter", message: message}]} =
               Proposal.parse("---\noutcome: done\n---\n\n# Title\n\nBody.")

      assert message =~ "only the ticket type"

      assert {:error, [%Error{path: "front_matter"}]} =
               Proposal.parse("---\ntype: bug\noutcome: done\n---\n# Title\n\nBody.")
    end

    test "reads the ticket type it suggests from front matter" do
      {:ok, proposal} = Proposal.parse("\n---\ntype: bug\n---\n\n# Title\n\nBody.")
      assert {proposal.ticket_type, proposal.title, proposal.body} == {"bug", "Title", "Body."}

      assert {:ok, %Proposal{ticket_type: "bug"}} =
               Proposal.parse(~s(---\ntype: "bug"\n---\n# Title\n\nBody.))

      assert {:ok, %Proposal{ticket_type: nil}} = Proposal.parse("---\n---\n# Title\n\nBody.")

      # Blank lines inside the front matter, and an opening `---` with trailing spaces, are still
      # front matter with a type in it.
      assert {:ok, %Proposal{ticket_type: "bug"}} =
               Proposal.parse("---\n\ntype: bug\n\n---\n# Title\n\nBody.")

      assert {:ok, %Proposal{ticket_type: "bug", title: "Title"}} =
               Proposal.parse("---  \ntype: bug\n---\n# Title\n\nBody.")

      assert {:ok, %Proposal{ticket_type: nil}} = Proposal.parse("# Title\n\nBody.")
    end

    test "refuses a type that is not a name, and front matter that is not closed" do
      assert {:error, [%Error{path: "type"}]} =
               Proposal.parse("---\ntype: ../bug\n---\n# Title\n\nBody.")

      assert {:error, [%Error{path: "type"}]} =
               Proposal.parse("---\ntype:\n---\n# Title\n\nBody.")

      assert {:error, [%Error{path: "front_matter", message: message}]} =
               Proposal.parse("---\ntype: bug\n# Title\n\nBody.")

      assert message =~ "not closed"
    end

    # A `---` further down is a thematic break in the body, not front matter.
    test "only the first non-blank line opens front matter" do
      {:ok, proposal} = Proposal.parse("# Title\n\nBefore.\n\n---\n\nAfter.")
      assert proposal.ticket_type == nil
      assert proposal.body =~ "After."
    end

    test "refuses a deeper heading" do
      assert {:error, [%Error{path: "title"}]} = Proposal.parse("## Title\n\nBody.")
    end

    test "refuses an empty proposal" do
      assert {:error, [%Error{path: "", message: "a proposal is empty"}]} = Proposal.parse("")

      assert {:error, [%Error{path: "", message: "a proposal is empty"}]} =
               Proposal.parse("\n \n")
    end

    test "refuses a heading with no text" do
      assert {:error, errors} = Proposal.parse("#\n\nBody.")
      assert Enum.any?(errors, &(&1.path == "title"))
    end

    test "refuses a title with no body, because a title alone does not say what the work is" do
      assert {:error, [%Error{path: "body", message: message}]} = Proposal.parse("# Title\n")
      assert message =~ "what the work is"
    end

    test "reports an empty title and an empty body together" do
      assert {:error, errors} = Proposal.parse("# \t \n\n   \n")
      assert Enum.map(errors, & &1.path) == ["title", "body"]
    end

    test "never raises on anything it is handed" do
      for text <- ["﻿# Title\n\nBody.", "#", "# ", "\r\n# Title\r\n\r\nBody.", "####"] do
        assert match?({:ok, _}, Proposal.parse(text)) or
                 match?({:error, [_ | _]}, Proposal.parse(text))
      end
    end

    test "strips a byte order mark rather than failing on it" do
      assert {:ok, %Proposal{title: "Title"}} = Proposal.parse("﻿# Title\n\nBody.")
    end

    test "handles CRLF line endings" do
      assert {:ok, %Proposal{title: "Title", body: "Body."}} =
               Proposal.parse("# Title\r\n\r\nBody.")
    end
  end

  describe "parse!/1" do
    test "returns the proposal when it reads" do
      assert %Proposal{title: "Title"} = Proposal.parse!("# Title\n\nBody.")
    end

    test "raises with the reason when it does not" do
      assert_raise ArgumentError, ~r/level-one heading/, fn -> Proposal.parse!("no heading") end
    end
  end

  describe "to_document/1" do
    test "is the shape admit/3 stores as the ticket artifact" do
      {:ok, proposal} = Proposal.parse("# Title\n\nBody.")

      assert Proposal.to_document(proposal) == "# Title\n\nBody."
    end

    test "round-trips through parse/1" do
      {:ok, proposal} = Proposal.parse("# A title\n\nA body\n\nover two paragraphs.")
      {:ok, again} = proposal |> Proposal.to_document() |> Proposal.parse()

      assert again.title == proposal.title
      assert again.body == proposal.body
    end

    # The suggestion is kept in the stored text, because the text is all that is stored; the
    # ticket a proposal becomes is admitted from the title and body alone.
    test "keeps a suggested type as front matter, and round-trips it" do
      {:ok, proposal} = Proposal.parse("---\ntype: bug\n---\n# Title\n\nBody.")

      assert Proposal.to_document(proposal) == "---\ntype: bug\n---\n# Title\n\nBody."

      assert {:ok, %Proposal{ticket_type: "bug", title: "Title"}} =
               proposal |> Proposal.to_document() |> Proposal.parse()
    end
  end
end
