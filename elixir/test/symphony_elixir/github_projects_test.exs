defmodule SymphonyElixir.GitHubProjectsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHubProjects.Client
  alias SymphonyElixir.StatusDashboard
  alias SymphonyElixir.Tracker.Issue

  describe "project url" do
    test "builds user and organization project urls" do
      assert StatusDashboard.project_url_for_test(%{
               kind: "github_projects",
               owner: "crypdick",
               owner_type: "user",
               project_number: 2
             }) == "https://github.com/users/crypdick/projects/2"

      assert StatusDashboard.project_url_for_test(%{
               kind: "github_projects",
               owner: "acme",
               owner_type: "organization",
               project_number: 5
             }) == "https://github.com/orgs/acme/projects/5"
    end

    test "returns nil when github project config is incomplete" do
      assert StatusDashboard.project_url_for_test(%{
               kind: "github_projects",
               owner: nil,
               owner_type: "user",
               project_number: nil
             }) == nil
    end
  end

  describe "normalize_issue_for_test/1" do
    test "maps a fully populated project item into a Tracker.Issue" do
      node = %{
        "id" => "PVTI_item1",
        "status" => %{"name" => "In progress"},
        "priority" => %{"name" => "P1"},
        "content" => %{
          "id" => "I_issue1",
          "number" => 42,
          "title" => "Add the thing",
          "body" => "details here",
          "url" => "https://github.com/crypdick/symphony/issues/42",
          "createdAt" => "2026-06-01T00:00:00Z",
          "updatedAt" => "2026-06-02T00:00:00Z",
          "assignees" => %{"nodes" => [%{"login" => "crypdick"}]},
          "labels" => %{"nodes" => [%{"name" => "Agent"}, %{"name" => "bug"}]},
          "blockedBy" => %{
            "nodes" => [
              %{"id" => "I_b1", "number" => 7, "state" => "OPEN"},
              %{"id" => "I_b2", "number" => 8, "state" => "CLOSED"}
            ]
          }
        }
      }

      assert %Issue{
               id: "PVTI_item1",
               content_id: "I_issue1",
               identifier: "#42",
               title: "Add the thing",
               description: "details here",
               url: "https://github.com/crypdick/symphony/issues/42",
               state: "In progress",
               priority: 1,
               branch_name: "symphony/issue-42-add-the-thing",
               assignee_id: "crypdick",
               labels: ["agent", "bug"],
               blocked_by: [
                 %{id: "I_b1", identifier: "#7", state: "Open"},
                 %{id: "I_b2", identifier: "#8", state: "Done"}
               ]
             } = Client.normalize_issue_for_test(node)
    end

    test "tolerates missing Status, Priority, assignees, labels and blockers" do
      node = %{
        "id" => "PVTI_item2",
        "status" => nil,
        "priority" => nil,
        "content" => %{
          "id" => "I_issue2",
          "number" => 99,
          "title" => "Bare issue",
          "body" => nil,
          "url" => "https://github.com/crypdick/symphony/issues/99",
          "assignees" => %{"nodes" => []},
          "labels" => %{"nodes" => []},
          "blockedBy" => %{"nodes" => []}
        }
      }

      assert %Issue{
               id: "PVTI_item2",
               content_id: "I_issue2",
               identifier: "#99",
               state: nil,
               priority: nil,
               assignee_id: nil,
               labels: [],
               blocked_by: [],
               branch_name: "symphony/issue-99-bare-issue"
             } = Client.normalize_issue_for_test(node)
    end

    test "returns nil for items whose content is not an issue (e.g. draft)" do
      assert Client.normalize_issue_for_test(%{"id" => "PVTI_x", "content" => nil}) == nil
    end
  end

  describe "fetch_items_for_test/1" do
    test "follows pagination and normalizes every page, dropping draft items" do
      page1 = %{
        "data" => %{
          "user" => %{
            "projectV2" => %{
              "id" => "PVT_proj",
              "items" => %{
                "nodes" => [
                  item_node("PVTI_1", "I_1", 1, "First", "Ready"),
                  %{"id" => "PVTI_draft", "content" => nil}
                ],
                "pageInfo" => %{"hasNextPage" => true, "endCursor" => "CURSOR_1"}
              }
            }
          }
        }
      }

      page2 = %{
        "data" => %{
          "user" => %{
            "projectV2" => %{
              "id" => "PVT_proj",
              "items" => %{
                "nodes" => [item_node("PVTI_2", "I_2", 2, "Second", "In progress")],
                "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
              }
            }
          }
        }
      }

      graphql_fun = fn _query, variables ->
        case variables[:after] do
          nil -> {:ok, page1}
          "CURSOR_1" -> {:ok, page2}
        end
      end

      assert {:ok, [%Issue{identifier: "#1", state: "Ready"}, %Issue{identifier: "#2", state: "In progress"}]} =
               Client.fetch_items_for_test(graphql_fun)
    end

    test "propagates graphql errors" do
      graphql_fun = fn _query, _variables -> {:error, :boom} end
      assert {:error, :boom} = Client.fetch_items_for_test(graphql_fun)
    end
  end

  defp item_node(item_id, content_id, number, title, status) do
    %{
      "id" => item_id,
      "status" => %{"name" => status},
      "priority" => nil,
      "content" => %{
        "id" => content_id,
        "number" => number,
        "title" => title,
        "body" => nil,
        "url" => "https://github.com/crypdick/symphony/issues/#{number}",
        "assignees" => %{"nodes" => []},
        "labels" => %{"nodes" => []},
        "blockedBy" => %{"nodes" => []}
      }
    }
  end
end
