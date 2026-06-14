defmodule SymphonyElixir.GitHubProjects.Client do
  @moduledoc """
  Thin GitHub GraphQL client for polling ProjectV2 items as candidate issues.

  GitHub's `ProjectV2.items` connection has no server-side field filter, so this
  client fetches every project item and normalizes it into `Tracker.Issue`.
  State/assignee filtering happens in `GitHubProjects.Adapter`.
  """

  require Logger
  alias SymphonyElixir.{Config, Tracker.Issue}

  @endpoint "https://api.github.com/graphql"
  @item_page_size 50
  @branch_slug_max 40
  @max_error_body_log_bytes 1_000

  @item_fields """
  {
    id
    status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
    priority: fieldValueByName(name: "Priority") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
    content {
      ... on Issue {
        id
        number
        title
        body
        url
        createdAt
        updatedAt
        assignees(first: 1) { nodes { login } }
        labels(first: 20) { nodes { name } }
        blockedBy(first: 20) { nodes { id number state } }
      }
    }
  }
  """

  @items_query_user """
  query SymphonyGitHubProjectItems($owner: String!, $number: Int!, $first: Int!, $after: String) {
    user(login: $owner) {
      projectV2(number: $number) {
        id
        items(first: $first, after: $after) {
          nodes #{@item_fields}
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @items_query_org """
  query SymphonyGitHubProjectItems($owner: String!, $number: Int!, $first: Int!, $after: String) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        items(first: $first, after: $after) {
          nodes #{@item_fields}
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @spec fetch_items() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_items do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_github_token}

      is_nil(tracker.owner) ->
        {:error, :missing_github_owner}

      is_nil(tracker.project_number) ->
        {:error, :missing_github_project_number}

      true ->
        do_fetch_items(&graphql/2, tracker.owner, owner_type(tracker), tracker.project_number, nil, [])
    end
  end

  @doc false
  @spec fetch_items_for_test((String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_items_for_test(graphql_fun) when is_function(graphql_fun, 2) do
    do_fetch_items(graphql_fun, "owner", "user", 1, nil, [])
  end

  defp do_fetch_items(graphql_fun, owner, owner_type, number, after_cursor, acc) do
    query = if owner_type == "organization", do: @items_query_org, else: @items_query_user

    variables = %{
      owner: owner,
      number: number,
      first: @item_page_size,
      after: after_cursor
    }

    with {:ok, body} <- graphql_fun.(query, variables),
         {:ok, nodes, page_info} <- decode_items_page(body) do
      issues = nodes |> Enum.map(&normalize_issue/1) |> Enum.reject(&is_nil/1)
      updated_acc = Enum.reverse(issues, acc)

      case page_info do
        %{"hasNextPage" => true, "endCursor" => cursor} when is_binary(cursor) ->
          do_fetch_items(graphql_fun, owner, owner_type, number, cursor, updated_acc)

        _ ->
          {:ok, Enum.reverse(updated_acc)}
      end
    end
  end

  defp decode_items_page(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:error, {:github_graphql_errors, errors}}
  end

  defp decode_items_page(body) when is_map(body) do
    project =
      get_in(body, ["data", "user", "projectV2"]) ||
        get_in(body, ["data", "organization", "projectV2"])

    case project do
      %{"items" => %{"nodes" => nodes, "pageInfo" => page_info}} when is_list(nodes) ->
        {:ok, nodes, page_info}

      _ ->
        {:error, :github_unknown_payload}
    end
  end

  defp owner_type(%{owner_type: "organization"}), do: "organization"
  defp owner_type(_tracker), do: "user"

  @spec graphql(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}) when is_binary(query) and is_map(variables) do
    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <-
           Req.post(@endpoint,
             headers: headers,
             json: %{"query" => query, "variables" => variables},
             connect_options: [timeout: 30_000]
           ) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error("GitHub GraphQL request failed status=#{response.status}" <> error_body(response))
        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_github_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Content-Type", "application/json"},
           {"User-Agent", "symphony"}
         ]}
    end
  end

  defp error_body(%{body: body}) when is_binary(body) do
    summary = body |> String.replace(~r/\s+/, " ") |> String.trim()
    " body=" <> inspect(String.slice(summary, 0, @max_error_body_log_bytes))
  end

  defp error_body(_response), do: ""

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(node) when is_map(node), do: normalize_issue(node)

  @spec normalize_issue(map()) :: Issue.t() | nil
  defp normalize_issue(%{"content" => content} = item) when is_map(content) do
    number = content["number"]
    title = content["title"]

    %Issue{
      id: item["id"],
      content_id: content["id"],
      identifier: issue_identifier(number),
      title: title,
      description: content["body"],
      priority: parse_priority(single_select_name(item["priority"])),
      state: single_select_name(item["status"]),
      branch_name: branch_name(number, title),
      url: content["url"],
      assignee_id: first_assignee_login(content),
      blocked_by: extract_blockers(content),
      labels: extract_labels(content),
      assigned_to_worker: true,
      created_at: parse_datetime(content["createdAt"]),
      updated_at: parse_datetime(content["updatedAt"])
    }
  end

  defp normalize_issue(_item), do: nil

  defp single_select_name(%{"name" => name}) when is_binary(name), do: name
  defp single_select_name(_), do: nil

  defp issue_identifier(number) when is_integer(number), do: "##{number}"
  defp issue_identifier(_), do: nil

  defp parse_priority(nil), do: nil

  defp parse_priority(value) when is_binary(value) do
    case Regex.run(~r/^P(\d+)$/i, String.trim(value)) do
      [_, digits] -> String.to_integer(digits)
      _ -> nil
    end
  end

  defp branch_name(number, title) when is_integer(number) do
    case slugify(title) do
      "" -> "symphony/issue-#{number}"
      slug -> "symphony/issue-#{number}-#{slug}"
    end
  end

  defp branch_name(_number, _title), do: nil

  defp slugify(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, @branch_slug_max)
    |> String.trim("-")
  end

  defp slugify(_title), do: ""

  defp first_assignee_login(%{"assignees" => %{"nodes" => [%{"login" => login} | _]}})
       when is_binary(login),
       do: login

  defp first_assignee_login(_content), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  defp extract_labels(_content), do: []

  defp extract_blockers(%{"blockedBy" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(fn node ->
      %{
        id: node["id"],
        identifier: issue_identifier(node["number"]),
        state: blocker_state(node["state"])
      }
    end)
  end

  defp extract_blockers(_content), do: []

  defp blocker_state("CLOSED"), do: "Done"
  defp blocker_state("OPEN"), do: "Open"
  defp blocker_state(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil
end
