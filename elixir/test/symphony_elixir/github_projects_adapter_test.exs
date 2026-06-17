defmodule SymphonyElixir.GitHubProjectsAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHubProjects.Adapter

  defmodule FakeClient do
    def fetch_items do
      Process.get({__MODULE__, :items}, {:ok, []})
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  setup do
    Application.put_env(:symphony_elixir, :github_client_module, FakeClient)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :github_client_module) end)
    :ok
  end

  defp put_items(issues), do: Process.put({FakeClient, :items}, {:ok, issues})

  defp configure_github_tracker!(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "github_projects",
          tracker_api_token: "ghp_token",
          tracker_owner: "crypdick",
          tracker_project_number: 2,
          tracker_active_states: ["Ready"]
        ],
        overrides
      )
    )
  end

  test "fetch_candidate_issues filters by active states and routes all issues when no assignee is configured" do
    configure_github_tracker!()

    put_items([
      %Issue{id: "1", state: "Ready", assigned_to_worker: false},
      %Issue{id: "2", state: "Done", assigned_to_worker: false}
    ])

    assert {:ok, [%Issue{id: "1", assigned_to_worker: true}]} = Adapter.fetch_candidate_issues()
  end

  test "fetch_candidate_issues filters candidate issues by configured assignee login" do
    configure_github_tracker!(tracker_assignee: "octocat")

    put_items([
      %Issue{id: "1", state: "Ready", assignee_id: "octocat"},
      %Issue{id: "2", state: "Ready", assignee_id: "someone-else"},
      %Issue{id: "3", state: nil, assignee_id: "octocat"}
    ])

    assert {:ok, [%Issue{id: "1", assigned_to_worker: true}]} = Adapter.fetch_candidate_issues()
  end

  test "fetch_candidate_issues resolves me through the GitHub viewer query" do
    configure_github_tracker!(tracker_assignee: "me")

    put_items([
      %Issue{id: "1", state: "Ready", assignee_id: "viewer-login"},
      %Issue{id: "2", state: "Ready", assignee_id: "someone-else"}
    ])

    Process.put(
      {FakeClient, :graphql_result},
      {:ok, %{"data" => %{"viewer" => %{"login" => "viewer-login"}}}}
    )

    assert {:ok, [%Issue{id: "1", assigned_to_worker: true}]} = Adapter.fetch_candidate_issues()
    assert_receive {:graphql_called, query, %{}}
    assert query =~ "viewer"
  end

  test "fetch_candidate_issues surfaces viewer lookup failures" do
    configure_github_tracker!(tracker_assignee: "me")
    put_items([%Issue{id: "1", state: "Ready", assignee_id: "viewer-login"}])

    Process.put({FakeClient, :graphql_result}, {:ok, %{"data" => %{"viewer" => nil}}})
    assert {:error, :missing_github_viewer_identity} = Adapter.fetch_candidate_issues()

    Process.put({FakeClient, :graphql_result}, {:error, :boom})
    assert {:error, :boom} = Adapter.fetch_candidate_issues()
  end

  test "fetch_issues_by_states filters case-insensitively and ignores non-string states" do
    items = [
      %Issue{id: "1", state: "Ready"},
      %Issue{id: "2", state: "In progress"},
      %Issue{id: "3", state: "Done"}
    ]

    put_items(items)

    assert {:ok, [%Issue{id: "1"}, %Issue{id: "2"}]} =
             Adapter.fetch_issues_by_states([" ready ", "IN PROGRESS", 42])
  end

  test "fetch_issues_by_states returns empty for empty state list" do
    put_items([%Issue{id: "1", state: "Ready"}])
    assert {:ok, []} = Adapter.fetch_issues_by_states([])
  end

  test "fetch_issue_states_by_ids selects only requested project item ids" do
    put_items([
      %Issue{id: "PVTI_1", state: "Ready"},
      %Issue{id: "PVTI_2", state: "Done"},
      %Issue{id: "PVTI_3", state: "In progress"}
    ])

    assert {:ok, [%Issue{id: "PVTI_1"}, %Issue{id: "PVTI_3"}]} =
             Adapter.fetch_issue_states_by_ids(["PVTI_1", "PVTI_3"])
  end

  test "fetch read callbacks propagate client errors" do
    Process.put({FakeClient, :items}, {:error, :boom})
    assert {:error, :boom} = Adapter.fetch_issues_by_states(["Ready"])
    assert {:error, :boom} = Adapter.fetch_issue_states_by_ids(["PVTI_1"])
  end

  test "create_comment posts addComment against the issue node id" do
    Process.put(
      {FakeClient, :graphql_result},
      {:ok, %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => %{"id" => "IC_1"}}}}}}
    )

    assert :ok = Adapter.create_comment("I_issue1", "hello")
    assert_receive {:graphql_called, query, %{subjectId: "I_issue1", body: "hello"}}
    assert query =~ "addComment"
  end

  test "create_comment surfaces failures and errors" do
    Process.put({FakeClient, :graphql_result}, {:ok, %{"data" => %{"addComment" => nil}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("I_x", "nope")

    Process.put({FakeClient, :graphql_result}, {:error, :boom})
    assert {:error, :boom} = Adapter.create_comment("I_x", "boom")
  end

  test "update_issue_state resolves the Status option then updates the field" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "project" => %{
                 "id" => "PVT_p",
                 "field" => %{
                   "id" => "F_status",
                   "options" => [
                     %{"id" => "opt-ready", "name" => "Ready"},
                     %{"id" => "opt-done", "name" => "Done"}
                   ]
                 }
               }
             }
           }
         }},
        {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_1"}}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("PVTI_1", "Done")
    assert_receive {:graphql_called, lookup_query, %{itemId: "PVTI_1"}}
    assert lookup_query =~ "options"

    assert_receive {:graphql_called, update_query, %{projectId: "PVT_p", itemId: "PVTI_1", fieldId: "F_status", optionId: "opt-done"}}

    assert update_query =~ "updateProjectV2ItemFieldValue"
  end

  test "update_issue_state errors when the Status option is missing" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "project" => %{"id" => "PVT_p", "field" => %{"id" => "F_status", "options" => []}}
             }
           }
         }}
      ]
    )

    assert {:error, :state_option_not_found} = Adapter.update_issue_state("PVTI_1", "Nope")
  end

  test "update_issue_state surfaces lookup and update payload failures" do
    Process.put({FakeClient, :graphql_results}, [{:error, :lookup_failed}])
    assert {:error, :lookup_failed} = Adapter.update_issue_state("PVTI_1", "Done")

    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "project" => %{
                 "id" => "PVT_p",
                 "field" => %{
                   "id" => "F_status",
                   "options" => [%{"id" => "opt-done", "name" => "Done"}]
                 }
               }
             }
           }
         }},
        {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => nil}}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("PVTI_1", "Done")
  end

  test "update_issue_state rejects malformed Status lookup payloads" do
    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "project" => %{
                 "id" => "PVT_p",
                 "field" => %{"id" => "F_status", "options" => nil}
               }
             }
           }
         }}
      ]
    )

    assert {:error, :state_option_not_found} = Adapter.update_issue_state("PVTI_1", "Done")

    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "project" => %{
                 "id" => "PVT_p",
                 "field" => %{"id" => "F_status", "options" => [%{"id" => "opt-empty", "name" => nil}]}
               }
             }
           }
         }}
      ]
    )

    assert {:error, :state_option_not_found} = Adapter.update_issue_state("PVTI_1", "Done")

    Process.put(
      {FakeClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "node" => %{
               "project" => %{"id" => "PVT_p", "field" => []}
             }
           }
         }}
      ]
    )

    assert {:error, :state_option_not_found} = Adapter.update_issue_state("PVTI_1", "Done")
  end
end
