defmodule Forge.UpdateWordsTest do
  @moduledoc """
  What an update step's visit says of itself, in words, from its payload
  (`docs/design/ui.md` § Steps, § Activity): the sentence, what became of the pin, and the
  reasons a ticket sticks or a re-pin is skipped.
  """

  use ExUnit.Case, async: true

  alias Forge.Events.Event
  alias Forge.Update

  @sha String.duplicate("a", 40)
  @other String.duplicate("b", 40)

  defp visit(result, extra \\ %{}) do
    Map.merge(
      %{"result" => result, "default_branch" => "main", "default" => @sha, "to" => @sha},
      extra
    )
  end

  describe "said/1" do
    test "current" do
      assert Update.said(visit("current")) == "already up to date with main at aaaaaaaaaaaa"
    end

    test "forwarded, with what it brought in" do
      assert Update.said(visit("forwarded")) == "moved forward to aaaaaaaaaaaa"

      assert Update.said(visit("forwarded", %{"merges" => [%{}], "more" => 0})) ==
               "moved forward to aaaaaaaaaaaa, bringing in 1 merge"
    end

    test "merged counts the merges listed and the ones left out" do
      merges = List.duplicate(%{}, 10)

      assert Update.said(visit("merged", %{"merges" => merges, "more" => 4})) ==
               "merged main at aaaaaaaaaaaa, bringing in 14 merges"

      assert Update.said(visit("merged", %{"merges" => [], "more" => 0})) ==
               "merged main at aaaaaaaaaaaa"
    end

    test "conflicted names the first path, the rest counted, and where it went" do
      said =
        Update.said(
          visit("conflicted", %{"paths" => ["a.ex", "b.ex", "c.ex"], "went" => "resolving"})
        )

      assert said == "conflicted with main in a.ex and 2 more; went to resolving"
    end

    test "conflicted while held says it waits for release, not that it stuck" do
      assert Update.said(visit("conflicted", %{"paths" => ["a.ex"], "held" => true})) ==
               "conflicted with main in a.ex; waits for release"
    end

    test "conflicted with nowhere to go says the ticket stuck, and cuts a long path" do
      long = String.duplicate("x", 300)
      said = Update.said(visit("conflicted", %{"paths" => [long]}))

      assert said == "conflicted with main in #{String.duplicate("x", 100)}; stuck"
    end

    test "failed says why, cut" do
      assert Update.said(visit("failed", %{"reason" => "git refused it: no"})) ==
               "could not bring the branch up to date: git refused it: no"

      assert String.length(
               Update.said(visit("failed", %{"reason" => String.duplicate("y", 900)}))
             ) ==
               String.length("could not bring the branch up to date: ") + 300
    end

    test "a payload it does not know is still a sentence, never its keys" do
      assert Update.said(%{"result" => "something-new", "x" => 1}) ==
               "brought the branch up to date"
    end
  end

  describe "file_refusal?/1" do
    test "the type's file's own reasons, and no other" do
      for code <- ~w(type_gone invalid unreadable), do: assert(Update.file_refusal?(code))
      for code <- ["no_state", "not_an_update_step", nil], do: refute(Update.file_refusal?(code))
    end
  end

  describe "repin_said/1" do
    test "re-pinned, not re-pinned and why, or nothing" do
      assert Update.repin_said(%{"repin" => %{"from" => @other, "to" => @sha}}) ==
               "re-pinned from #{String.slice(@other, 0, 12)} to aaaaaaaaaaaa"

      assert Update.repin_said(%{"repin" => %{"to" => @sha}}) == "re-pinned to aaaaaaaaaaaa"

      assert Update.repin_said(%{"repin" => %{"skipped" => "invalid", "reason" => "no state x"}}) ==
               "not re-pinned: no state x"

      assert Update.repin_said(%{"repin" => nil}) == nil
      assert Update.repin_said(%{}) == nil
    end
  end

  describe "the reasons" do
    test "a conflict with nowhere to go lists three paths and counts the rest" do
      assert Update.conflict_words(["a"], "main") ==
               "bringing the branch up to date with main conflicted in a"

      assert Update.conflict_words(["a", "b", "c", "d", "e"], "main") ==
               "bringing the branch up to date with main conflicted in a, b, c and 2 more"
    end

    test "a failed visit says what failed, in words" do
      assert Update.failed_words({:error, :branch_moving}, "main") =~
               "pushed to twice while it was being brought up to date; someone is pushing to it by hand"

      assert Update.failed_reason(:job_live) == "a job of this ticket is still running"
      assert Update.failed_reason({1, "no"}) == "git refused it: {1, \"no\"}"
    end

    test "a skipped re-pin says what stopped the workflow being read" do
      assert Update.skip_words({:ticket_type_gone, "bug", ".forge/workflows/bug.yml"}) ==
               "the workflow file .forge/workflows/bug.yml is gone there"

      errors = [
        ForgeCore.Error.new("states.a", "is not reachable from initial"),
        ForgeCore.Error.new("states.b", "is not reachable from initial")
      ]

      assert Update.skip_words(errors) ==
               "the workflow there does not validate: states.a is not reachable from initial (and 1 more)"

      assert Update.skip_words(:enoent) == "the workflow there could not be read: :enoent"
    end
  end

  describe "Forge.Events.summary/1" do
    defp event(type, payload, actor \\ %{"kind" => "system"}),
      do: %Event{type: type, payload: payload, actor: actor}

    test "joins what it did and what became of the pin" do
      payload =
        visit("forwarded", %{
          "repin" => %{"skipped" => "no_state", "reason" => "no state refresh"}
        })

      assert Forge.Events.summary(event("ticket.branch_updated", payload)) ==
               "moved forward to aaaaaaaaaaaa; not re-pinned: no state refresh"

      assert Forge.Events.summary(event("ticket.branch_updated", visit("current"))) ==
               "already up to date with main at aaaaaaaaaaaa"
    end

    test "says the engine's re-pin, a person's, a moved base and a conversation's merge" do
      assert Forge.Events.summary(event("ticket.repinned", %{"from" => @other, "to" => @sha})) ==
               "workflow re-pinned by the engine, bbbbbbbbbbbb → aaaaaaaaaaaa"

      assert Forge.Events.summary(
               event("ticket.repinned", %{"from" => @other, "to" => @sha}, %{"kind" => "user"})
             ) == "workflow re-pinned bbbbbbbbbbbb → aaaaaaaaaaaa"

      assert Forge.Events.summary(event("ticket.base_moved", %{"from" => @other, "to" => @sha})) ==
               "base moved bbbbbbbbbbbb → aaaaaaaaaaaa"

      assert Forge.Events.summary(event("chat.merged", %{"chat" => "c1", "sha" => @sha})) ==
               "a conversation's work merged as aaaaaaaaaaaa"
    end
  end
end
