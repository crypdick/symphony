ExUnit.start()

# Keep GitHub token resolution deterministic in tests: never shell out to `gh`.
# Individual tests override `:gh_token_resolver` to exercise resolution paths.
Application.put_env(:symphony_elixir, :gh_token_resolver, fn -> nil end)

Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
