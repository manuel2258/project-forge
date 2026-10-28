defmodule ForgeWeb.Operator.AdmissionReleaseTest do
  @moduledoc """
  The sentences for the release's refusals (`docs/design/ticket-types.md` § Releases). The other
  tests assert the reason tuples; a person reads these.
  """

  use ExUnit.Case, async: true

  alias ForgeWeb.Operator.Admission

  test "each says what is wrong in words" do
    assert Admission.explain({:release_ticket_type, "release"}) ==
             "release is this project's release, which a project admin starts with Release on " <>
               "the project page"

    assert Admission.explain({:only_release_types, [".forge/workflows/release.yml"]}) ==
             "its only workflow is its release (.forge/workflows/release.yml), which a project " <>
               "admin starts with Release on the project page, so it has no type for an " <>
               "ordinary ticket"

    assert Admission.explain({:release_open, %{number: 7}}) == "a release is already open: #7"
    assert Admission.explain({:invalid_note, "is too big"}) == "the note is too big"

    assert Admission.explain({:several_release_workflows, ["a.yml", "b.yml"]}) ==
             "a.yml and b.yml both set release: true, so the project has no release; unset it " <>
               "in all but one"
  end
end
