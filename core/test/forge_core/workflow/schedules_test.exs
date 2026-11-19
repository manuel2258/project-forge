defmodule ForgeCore.Workflow.SchedulesTest do
  @moduledoc """
  `schedules:` (`docs/design/workflow-grammar-v1.md` § Schedules): what the parser reads and what
  the validator refuses, each by the path of the entry and the key. A pin is built without the
  validator, so one from before schedules existed reads as none.
  """

  use ExUnit.Case, async: true

  alias ForgeCore.Workflow.{Parser, Schedule}

  @base """
  version: 1
  initial: working
  states:
    working:
      prompt: agents/work.md
      produces: [out.md]
      budget: { turns: 5, tokens: 200k }
    finished: {}
  transitions:
    - { from: working, to: finished }
  limits: { ticket_tokens: 1M }
  """

  defp map(extra \\ %{}) do
    {:ok, map} = YamlElixir.read_from_string(@base)
    Map.merge(map, extra)
  end

  defp entry(changes \\ %{}) do
    Map.merge(
      %{
        "name" => "weekly-cleanup",
        "cron" => "0 6 * * MON",
        "title" => "Weekly cleanup",
        "body" => "Tidy up."
      },
      changes
    )
  end

  defp errors(extra, opts \\ []) do
    assert {:error, errors} = Parser.from_map(map(extra), opts)
    Enum.map(errors, &{&1.path, &1.message})
  end

  test "a workflow with no schedules has none" do
    assert {:ok, workflow} = Parser.from_map(map())
    assert workflow.schedules == []
  end

  test "schedules are read in order, as written" do
    extra = %{"schedules" => [entry(), entry(%{"name" => "monthly", "cron" => "0 0 1 * *"})]}

    assert {:ok, workflow} = Parser.from_map(map(extra))

    assert [
             %Schedule{
               name: "weekly-cleanup",
               cron: "0 6 * * MON",
               title: "Weekly cleanup",
               body: "Tidy up."
             },
             %Schedule{name: "monthly", cron: "0 0 1 * *"}
           ] = workflow.schedules
  end

  test "an empty list is none" do
    assert {:ok, %{schedules: []}} = Parser.from_map(map(%{"schedules" => []}))
  end

  test "both forms of file take them" do
    assert {:ok, _} = Parser.from_map(map(%{"schedules" => [entry()]}), single_file: true)
    assert {:ok, _} = Parser.from_map(map(%{"schedules" => [entry()]}), single_file: false)
  end

  test "a pin without the key reads as none, and one with it reads as it was admitted" do
    {:ok, pin} = Parser.from_pinned(map())
    assert pin.schedules == []

    # A cron line a later grammar would refuse is still built: a pin is not validated again.
    stale = entry(%{"cron" => "not a cron line"})
    assert {:ok, pinned} = Parser.from_pinned(map(%{"schedules" => [stale]}))
    assert [%Schedule{cron: "not a cron line"}] = pinned.schedules
  end

  describe "refused" do
    test "a mapping, or anything that is not a list" do
      assert [{"schedules", "must be a list of schedules"}] =
               errors(%{"schedules" => %{"weekly" => entry()}})

      assert [{"schedules", "must be a list of schedules"}] = errors(%{"schedules" => "weekly"})
    end

    test "an entry that is not a mapping" do
      assert [{"schedules[0]", "must be a mapping"}] = errors(%{"schedules" => ["weekly"]})
    end

    for key <- ~w(name cron title body) do
      test "an entry without #{key}" do
        assert [{path, "is required"}] =
                 errors(%{"schedules" => [Map.delete(entry(), unquote(key))]})

        assert path == "schedules[0].#{unquote(key)}"
      end

      test "an entry whose #{key} is not a string" do
        assert [{path, "must be a non-empty string"}] =
                 errors(%{"schedules" => [entry(%{unquote(key) => 5})]})

        assert path == "schedules[0].#{unquote(key)}"
      end
    end

    test "an unknown key, at the entry and the key" do
      assert [{"schedules[1].timezone", "unknown key"}] =
               errors(%{"schedules" => [entry(), entry(%{"name" => "b", "timezone" => "UTC"})]})
    end

    for key <- ~w(title body) do
      test "a blank #{key}" do
        assert [{path, "must not be blank"}] =
                 errors(%{"schedules" => [entry(%{unquote(key) => "  \n "})]})

        assert path == "schedules[0].#{unquote(key)}"
      end
    end

    test "a name that is not a name, by the rule of a state's" do
      for name <- ["has space", "../up", ".hidden", "a/b", "name\n"] do
        assert [{"schedules[0].name", message}] =
                 errors(%{"schedules" => [entry(%{"name" => name})]})

        assert message =~ "letters, digits"
      end
    end

    test "two of one name, at the second" do
      assert [{"schedules[1].name", message}] =
               errors(%{"schedules" => [entry(), entry(%{"cron" => "0 0 * * *"})]})

      assert message =~ "declared twice"
    end

    test "a third of one name is refused at each repeat" do
      assert [{"schedules[1].name", _}, {"schedules[2].name", _}] =
               errors(%{"schedules" => [entry(), entry(), entry()]})
    end

    test "a malformed cron line, naming the field" do
      assert [{"schedules[0].cron", message}] =
               errors(%{"schedules" => [entry(%{"cron" => "61 * * * *"})]})

      assert message =~ "minute: 61 is out of range"

      assert [{"schedules[0].cron", message}] =
               errors(%{"schedules" => [entry(%{"cron" => "@weekly"})]})

      assert message =~ "five fields"
    end

    test "a cron line that never comes due" do
      assert [{"schedules[0].cron", message}] =
               errors(%{"schedules" => [entry(%{"cron" => "0 0 30 2 *"})]})

      assert message =~ "never comes due"
    end

    test "a name or a cron line longer than the platform keeps is refused, and the longest is not" do
      long_cron = String.duplicate("0,", 95) <> "00 9 * * 1"
      assert byte_size(long_cron) == 200

      assert {:ok, _} =
               Parser.from_map(
                 map(%{
                   "schedules" => [
                     entry(%{"name" => String.duplicate("a", 100), "cron" => long_cron})
                   ]
                 })
               )

      assert [{"schedules[0].name", message}] =
               errors(%{"schedules" => [entry(%{"name" => String.duplicate("a", 101)})]})

      assert message =~ "longer than 100"

      assert [{"schedules[0].cron", message}] =
               errors(%{"schedules" => [entry(%{"cron" => "0" <> long_cron})]})

      assert message =~ "longer than 200"
    end

    test "any number of faults are all reported" do
      assert [{"schedules[0].body", _}, {"schedules[1].cron", _}, {"schedules[1].name", _}] =
               errors(%{
                 "schedules" => [
                   entry(%{"body" => " "}),
                   entry(%{"cron" => "x", "name" => "bad name"})
                 ]
               })
               |> Enum.sort()
    end

    test "any schedule in a release file, once, whatever its entries" do
      assert [{"schedules", message}] =
               errors(%{"release" => true, "schedules" => [entry(), entry(%{"name" => "b"})]})

      assert message =~ "never admits a release"
    end

    test "a release file with none is as before" do
      assert {:ok, _} = Parser.from_map(map(%{"release" => true}))
    end

    test "schedules in a library" do
      library = "schedules:\n  - { name: a, cron: '* * * * *', title: t, body: b }\n"
      read = fn "common.yml" -> {:ok, library} end

      assert {:error, errors} =
               Parser.load(@base <> "import: [common.yml]\n", read_library: read)

      assert Enum.any?(
               errors,
               &(&1.path == "schedules" and &1.message =~ "not allowed in a library")
             )
    end
  end
end
