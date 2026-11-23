defmodule ForgeWeb.Components.StepAcceptTest do
  @moduledoc """
  What a step says in place while it has no row (`docs/design/ui.md` § The Accept area): in a
  conversation's dock a phone does not draw *Nothing to accept yet*, and what stays at every width
  is *the step is over* and *Waiting for the reply to finish*.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ForgeWeb.Components.StepAccept

  defp step(attrs) do
    Map.merge(
      %{
        over: nil,
        in_flight: false,
        documents: [%{name: "refinement.md", own: true, version: nil}]
      },
      attrs
    )
  end

  defp status(step, dock) do
    render_component(&StepAccept.status/1, step: step, dock: dock) |> Floki.parse_fragment!()
  end

  test "in the dock a phone is not told there is nothing to accept yet" do
    html = status(step(%{}), true)

    assert [{"section", attrs, _}] = Floki.find(html, "#step-status")
    assert Enum.any?(attrs, fn {k, v} -> k == "class" and v =~ "max-md:hidden" end)

    assert [{"p", p_attrs, _}] = Floki.find(html, "#step-nothing-yet")
    assert Enum.any?(p_attrs, fn {k, v} -> k == "class" and v =~ "max-md:hidden" end)
  end

  test "out of the dock the sentence is drawn at every width" do
    html = status(step(%{}), false)

    refute Floki.raw_html(html) =~ "max-md:hidden"
    assert Floki.text(Floki.find(html, "#step-nothing-yet")) =~ "Nothing to accept yet"
  end

  # The section holds more than the sentence, so only the sentence goes.
  test "in the dock, waiting for the reply stays at every width" do
    html = status(step(%{in_flight: true}), true)

    assert Floki.text(Floki.find(html, "#step-waiting")) =~ "Waiting for the reply to finish"
    [{"section", attrs, _}] = Floki.find(html, "#step-status")
    refute Enum.any?(attrs, fn {k, v} -> k == "class" and v =~ "max-md:hidden" end)
    assert Floki.raw_html(Floki.find(html, "#step-nothing-yet")) =~ "max-md:hidden"
    refute Floki.raw_html(Floki.find(html, "#step-waiting")) =~ "max-md:hidden"
  end

  test "in the dock, the step being over stays at every width" do
    html = status(step(%{over: :accepted}), true)

    assert Floki.text(Floki.find(html, "#step-over")) =~ "This step was accepted."
    refute Floki.raw_html(html) =~ "max-md:hidden"
  end
end
