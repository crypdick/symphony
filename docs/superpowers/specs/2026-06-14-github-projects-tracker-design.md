# GitHub Projects Tracker Backend — Design

**Date:** 2026-06-14
**Status:** Approved (design forks confirmed via clarifying questions)

## Goal

Migrate Symphony's work source from Linear to GitHub Projects. Symphony polls a
tracker board for candidate issues and spawns Codex agents to implement them.
This design adds a GitHub Projects (ProjectsV2) backend as a parallel tracker
adapter and makes it the default, while leaving the Linear and memory adapters
in place.

## Confirmed decisions

1. **Strategy:** parallel adapter. New `github_projects` tracker kind alongside
   `linear` and `memory`. Default flips to `github_projects`. Reversible via
   config; Linear code stays but is no longer the default.
2. **Auth:** resolve a token into the existing `tracker.api_key` slot. Order:
   explicit config → `GITHUB_TOKEN` env → `gh auth token` (shell). Needs
   `project` + `repo` scopes (the authed `gh` CLI already has these).
3. **Blockers:** use GitHub's native issue dependencies — `issue.blockedBy`
   (GraphQL field, verified available).
4. **Priority / branch:** Priority = a single-select **Priority** field on the
   Project (`P0→0 … P2→2`). Branch names are Symphony-generated
   (`symphony/issue-<number>-<slug>`) since GitHub has no native branch name.

## Architecture

The `SymphonyElixir.Tracker` behaviour is the adapter seam (5 callbacks):

- `fetch_candidate_issues/0`
- `fetch_issues_by_states/1`
- `fetch_issue_states_by_ids/1`
- `create_comment/2`
- `update_issue_state/2`

`Tracker.adapter/0` selects the implementation by `Config.settings!().tracker.kind`.
We add a `"github_projects"` branch returning `SymphonyElixir.GitHubProjects.Adapter`.

### New modules

- `SymphonyElixir.GitHubProjects.Client` — thin GitHub GraphQL client
  (`https://api.github.com/graphql`, `Authorization: Bearer <token>`). Polls
  ProjectV2 items, resolves field/option ids, runs mutations. Mirrors
  `Linear.Client` structure (swappable `client_module`, `*_for_test` helpers).
- `SymphonyElixir.GitHubProjects.Adapter` — implements `Tracker`, delegates to
  `Client`, maps comment/state operations.

### Shared issue struct

Move `SymphonyElixir.Linear.Issue` → `SymphonyElixir.Tracker.Issue` (fields are
already backend-agnostic). Update alias sites: `orchestrator.ex`,
`prompt_builder.ex`, `agent_runner.ex`, `Linear.Client`, `Linear.Adapter`. Both
adapters return `Tracker.Issue`.

`Issue.id` carries the **ProjectV2Item id** (needed for Status field updates).
Add `content_id` (the underlying **Issue node id**, needed for `addComment`).
Linear conflated these; GitHub separates them.

## Data model mapping

| `Tracker.Issue` field | GitHub source |
|---|---|
| `id` | `ProjectV2Item.id` |
| `content_id` (new) | `Issue.id` (node id of the issue) |
| `identifier` | `#<number>` |
| `title`, `description` (body), `url` | native issue fields |
| `priority` | **Priority** single-select option name → integer (`P0`→0) |
| `state` | **Status** single-select option name |
| `branch_name` | generated: `symphony/issue-<number>-<slug>` |
| `assignee_id` | first assignee `login` |
| `labels` | native issue labels (downcased) |
| `blocked_by` | `issue.blockedBy.nodes` → `[{id, identifier, state}]` |
| `created_at`, `updated_at` | native issue timestamps |

### State resolution

`update_issue_state(item_id, state_name)` must resolve the Status field id and
the target option id (e.g. `In progress` → `47fc9ee4`), then call
`updateProjectV2ItemFieldValue(input: {projectId, itemId, fieldId, value:
{singleSelectOptionId}})`. Field/option ids are resolved per project and are
cacheable. This mirrors how `Linear.Adapter.resolve_state_id/2` resolves state
names → stateIds today.

### Comments

`create_comment(content_id, body)` → `addComment(input: {subjectId: content_id,
body})`. Comments attach to the underlying issue, not the project item.

## Config changes

`Config.Schema.Tracker` embedded schema — add fields:

- `owner` — project owner login (e.g. `crypdick`)
- `project_number` — integer (e.g. `2`)
- `status_field` — default `"Status"`
- `priority_field` — default `"Priority"`

Keep `project_slug` for Linear. `endpoint` default stays Linear's; the
GitHub client defaults its own endpoint when unset.

`config.ex` validation:

- Add `github_projects` to allowed `kind` values.
- For `github_projects`: require `api_key` (after resolution), `owner`,
  `project_number`.

State defaults for GitHub are set in `WORKFLOW.md`, not the schema (schema keeps
Linear-flavored defaults for Linear users):

- `active_states = ["Ready", "In progress"]`
- `terminal_states = ["Done"]`

### Auth resolution

In `Config.Schema.finalize_settings/1`, when `kind == "github_projects"` and
`api_key` is unset, resolve `GITHUB_TOKEN` then `gh auth token`. Keep the
existing Linear `LINEAR_API_KEY` path for the Linear kind.

## Agent-facing tooling

`Codex.DynamicTool` becomes **kind-aware**:

- `github_projects` → expose `github_graphql` (raw GraphQL against
  api.github.com via the GitHub client) + `sync_workpad` remapped to GitHub
  issue comments (`addComment` create / `updateIssueComment` update).
- `linear` → keep `linear_graphql` + Linear `sync_workpad`.

Tool specs and execution dispatch select the client by tracker kind.

## New agent skill

`.agents/skills/github-projects/SKILL.md` — GraphQL patterns for ProjectsV2,
structured like the existing Linear skill:

- Workpad: create via `addComment`, update via `updateIssueComment`, persist
  comment id to `.workpad-id`.
- Query a project item / issue (number, title, body, status, labels, url).
- State transitions via `updateProjectV2ItemFieldValue` (resolve field+option
  ids first — never hardcode).
- Attach a PR: prefer `Closes #<n>` in the PR body; otherwise `addComment` with
  the PR URL.
- Read blockers via `issue.blockedBy`.
- Rules: no schema introspection; narrowly scoped queries; sync at milestones.

Keep the Linear skill in place.

## Docs sweep

- `README.md`, `SPEC.md` — describe GitHub Projects as the work source.
- `elixir/README.md`, `elixir/WORKFLOW.md`, `elixir/AGENTS.md` — config and
  setup for `github_projects`.
- `status_dashboard.ex` — Linear project URL → GitHub project URL
  (`https://github.com/users/<owner>/projects/<number>`), kind-aware.
- `mix/tasks/workspace.before_remove.ex` — terminal-state close message wording.
- Module `@moduledoc`s referencing Linear in orchestrator / agent_runner /
  prompt_builder → tracker-neutral wording.

## Testing strategy

Each adapter callback is a pure transform over GraphQL JSON. Follow the existing
fixture-driven pattern (`Client.normalize_issue_for_test`,
`fetch_issue_states_by_ids_for_test`). TDD:

1. `Tracker.Issue` rename — existing tests pass with updated aliases.
2. `GitHubProjects.Client` normalization — fixtures for ProjectV2 item +
   issue payloads → `Tracker.Issue`.
3. `GitHubProjects.Client` field/option id resolution + mutation payload shape.
4. `GitHubProjects.Adapter` — comment + state-update happy/error paths with a
   stubbed client module.
5. `Tracker.adapter/0` selection for `github_projects`.
6. Config schema + validation for the new kind/fields and auth resolution.
7. `DynamicTool` kind-aware tool specs + dispatch.

## Out of scope (v1)

- Migrating existing Linear ticket data into GitHub (the project starts empty).
- GitHub App auth (token-only for now).
- Multi-repo project items beyond the configured repo.
- Priority values beyond the Project's defined options.

## Non-obvious facts (verified against live API)

- Project is User-owned: owner `crypdick`, number `2`.
- Status options: Backlog, Ready, In progress, In review, Done.
- Priority options: P0, P1, P2.
- `Issue.blockedBy` / `blocking` / `subIssues` / `parent` are GraphQL-queryable.
- `gh auth token` works; token scopes include `project`, `repo`, `workflow`.
