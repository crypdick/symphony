---
name: github-projects
description: |
  GitHub GraphQL patterns for Symphony agents working a GitHub Projects (ProjectsV2)
  board. Use `github_graphql` for all operations — comments, Status transitions,
  PR links, and reading blockers. Never use schema introspection.
---

# GitHub Projects GraphQL

All GitHub operations go through the `github_graphql` client tool exposed by
Symphony's app server. It handles auth automatically (it uses Symphony's
configured token).

```json
{
  "query": "query or mutation document",
  "variables": { "optional": "graphql variables" }
}
```

One operation per tool call. A top-level `errors` array means the operation
failed even if the tool call completed.

## Two ids you must keep straight

- **Issue node id** (`I_...`) — the GraphQL id of the underlying issue. Use it
  to comment (`addComment.subjectId`) and to read issue fields.
- **Project item id** (`PVTI_...`) — the id of the issue *as an item on the
  project board*. Use it to change **Status**.

The orchestrator injects both, plus identifier (`#42`), title, body, status,
labels, and url, into your prompt at startup. You usually do not need to re-read.

## Workpad

Maintain a local `workpad.md` in your workspace. Edit freely (zero API cost),
then sync to GitHub at milestones — plan finalized, implementation done,
validation complete. Do not sync after every small change.

**First sync** — create the comment on the issue, save the id:

```graphql
mutation CreateComment($subjectId: ID!, $body: String!) {
  addComment(input: { subjectId: $subjectId, body: $body }) {
    commentEdge { node { id url } }
  }
}
```

Write the returned `commentEdge.node.id` to `.workpad-id` so subsequent syncs
can update.

**Subsequent syncs** — read `.workpad-id`, update in place:

```graphql
mutation UpdateComment($id: ID!, $body: String!) {
  updateIssueComment(input: { id: $id, body: $body }) { issueComment { id } }
}
```

(The `sync_workpad` tool wraps both of these — prefer it when available.)

## Query an issue

By number within the repository:

```graphql
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      id
      number
      title
      url
      body
      state
      labels(first: 20) { nodes { name } }
    }
  }
}
```

For comments:

```graphql
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      comments(first: 50) { nodes { id body author { login } createdAt } }
    }
  }
}
```

## Status transitions

Status is a single-select field on the **project**, not on the issue. Resolve
the project id, the Status field id, and the target option id first, then set
it. Never hardcode option ids.

Resolve from the project item id:

```graphql
query($itemId: ID!) {
  node(id: $itemId) {
    ... on ProjectV2Item {
      project {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField { id options { id name } }
        }
      }
    }
  }
}
```

Then move it:

```graphql
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { singleSelectOptionId: $optionId }
    }
  ) {
    projectV2Item { id }
  }
}
```

## Attach a PR

Prefer GitHub's native linkage: put `Closes #<number>` (or `Fixes #<number>`)
in the PR body so the PR auto-links and closes the issue on merge. If you also
want a visible pointer, post it on the workpad or as a comment:

```graphql
mutation($subjectId: ID!, $body: String!) {
  addComment(input: { subjectId: $subjectId, body: $body }) {
    commentEdge { node { id url } }
  }
}
```

## Read blockers

A blocked issue is one with non-closed `blockedBy` dependencies:

```graphql
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      blockedBy(first: 20) { nodes { number state } }
    }
  }
}
```

A blocker is resolved when its `state` is `CLOSED`.

## Create a follow-up issue

```graphql
mutation($repositoryId: ID!, $title: String!, $body: String!) {
  createIssue(input: { repositoryId: $repositoryId, title: $title, body: $body }) {
    issue { id number url }
  }
}
```

Then add it to the project board and express dependencies with sub-issues /
issue dependencies as needed.

## Rules

- **No introspection.** Never use `__type` or `__schema` queries. They return a
  huge schema and waste the context window. Every pattern you need is above.
- Keep queries narrowly scoped — ask only for fields you need.
- Sync the workpad at milestones, not after every change.
- For Status transitions, always resolve the field + option ids first — never
  hardcode them.
- Prefer `Closes #<number>` in the PR body over a bare comment for PR linkage.
- Comment on the **issue node id** (`subjectId`); change Status on the
  **project item id**.
