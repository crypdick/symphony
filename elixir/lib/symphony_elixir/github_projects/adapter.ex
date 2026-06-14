defmodule SymphonyElixir.GitHubProjects.Adapter do
  @moduledoc """
  GitHub Projects (ProjectV2) tracker adapter.

  Reads delegate to `GitHubProjects.Client.fetch_items/0` (all project items)
  and filter client-side, since GitHub has no server-side field filter. Writes
  comment on the underlying issue and update the project item's Status field.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, GitHubProjects.Client}

  @status_field "Status"

  @add_comment_mutation """
  mutation SymphonyAddComment($subjectId: ID!, $body: String!) {
    addComment(input: {subjectId: $subjectId, body: $body}) {
      commentEdge { node { id } }
    }
  }
  """

  @status_lookup_query """
  query SymphonyResolveStatusOption($itemId: ID!) {
    node(id: $itemId) {
      ... on ProjectV2Item {
        project {
          id
          field(name: "#{@status_field}") {
            ... on ProjectV2SingleSelectField { id options { id name } }
          }
        }
      }
    }
  }
  """

  @update_status_mutation """
  mutation SymphonyUpdateStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(
      input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: {singleSelectOptionId: $optionId}}
    ) {
      projectV2Item { id }
    }
  }
  """

  @viewer_query "query SymphonyViewer { viewer { login } }"

  @impl true
  @spec fetch_candidate_issues() :: {:ok, [SymphonyElixir.Tracker.Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with {:ok, issues} <- client_module().fetch_items(),
         {:ok, assignee} <- resolve_assignee(tracker.assignee) do
      filtered =
        issues
        |> filter_by_states(tracker.active_states)
        |> Enum.map(&apply_assignee(&1, assignee))
        |> Enum.filter(& &1.assigned_to_worker)

      {:ok, filtered}
    end
  end

  @impl true
  @spec fetch_issues_by_states([term()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    with {:ok, issues} <- client_module().fetch_items() do
      {:ok, filter_by_states(issues, states)}
    end
  end

  @impl true
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(ids) do
    id_set = MapSet.new(ids)

    with {:ok, issues} <- client_module().fetch_items() do
      {:ok, Enum.filter(issues, &MapSet.member?(id_set, &1.id))}
    end
  end

  @impl true
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(subject_id, body) when is_binary(subject_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@add_comment_mutation, %{subjectId: subject_id, body: body}),
         id when is_binary(id) <- get_in(response, ["data", "addComment", "commentEdge", "node", "id"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @impl true
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(item_id, state_name) when is_binary(item_id) and is_binary(state_name) do
    with {:ok, project_id, field_id, option_id} <- resolve_status_option(item_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_status_mutation, %{
             projectId: project_id,
             itemId: item_id,
             fieldId: field_id,
             optionId: option_id
           }),
         id when is_binary(id) <-
           get_in(response, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  defp resolve_status_option(item_id, state_name) do
    with {:ok, response} <- client_module().graphql(@status_lookup_query, %{itemId: item_id}),
         field when is_map(field) <- get_in(response, ["data", "node", "project", "field"]),
         project_id when is_binary(project_id) <- get_in(response, ["data", "node", "project", "id"]),
         option when is_map(option) <- find_option(field["options"], state_name) do
      {:ok, project_id, field["id"], option["id"]}
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :state_option_not_found}
      _ -> {:error, :state_option_not_found}
    end
  end

  defp find_option(options, state_name) when is_list(options) do
    target = normalize(state_name)
    Enum.find(options, fn option -> normalize(option["name"]) == target end)
  end

  defp find_option(_options, _state_name), do: nil

  defp filter_by_states(issues, states) do
    state_set =
      states
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize/1)
      |> MapSet.new()

    if MapSet.size(state_set) == 0 do
      []
    else
      Enum.filter(issues, fn issue ->
        is_binary(issue.state) and MapSet.member?(state_set, normalize(issue.state))
      end)
    end
  end

  defp resolve_assignee(nil), do: {:ok, nil}

  defp resolve_assignee("me") do
    case client_module().graphql(@viewer_query, %{}) do
      {:ok, response} ->
        case get_in(response, ["data", "viewer", "login"]) do
          login when is_binary(login) -> {:ok, login}
          _ -> {:error, :missing_github_viewer_identity}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_assignee(login) when is_binary(login), do: {:ok, login}

  defp apply_assignee(issue, nil), do: %{issue | assigned_to_worker: true}

  defp apply_assignee(issue, login) do
    %{issue | assigned_to_worker: issue.assignee_id == login}
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize(_value), do: ""

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
