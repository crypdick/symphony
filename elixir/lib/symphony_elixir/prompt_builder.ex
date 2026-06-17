defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from tracker issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]
  @operational_guidance_heading "## Symphony operational guidance"
  @operational_guidance """
  #{@operational_guidance_heading}

  - This is an unattended orchestration session. Work autonomously from the tracker issue, workflow instructions, repository state, and available tools.
  - Keep the main agent thread token-efficient: preserve decisions, edit intent, validation evidence, and final handoff; avoid pasting large file contents, full logs, broad directory listings, or coverage tables unless directly needed.
  - Use subagents or delegated agents only when the task is broad, ambiguous, or benefits from parallel inspection. Good delegation targets include codebase scouting, locating relevant files, summarizing existing tests/docs, reviewing a diff, and diagnosing a specific validation failure.
  - Give each subagent enough focused context to succeed: issue identifier/title, exact question, relevant workflow constraints, known files or commands to inspect, and the expected return shape. Ask for concise findings with file paths, useful line references, commands run, and uncertainties.
  - Do not overload subagents with unnecessary transcript history or unbounded exploration. If scope grows, send a second focused prompt instead of one oversized prompt.
  - Use stage checkpoints instead of carrying all reasoning in the main transcript. For non-trivial work, keep compact Scout -> Implement -> Verify -> Review/Repair -> Handoff notes in the workpad or local scratch files; each checkpoint should capture only decisions, touched paths, validation plan/results, and open risks.
  - For non-trivial Scout, Review, and focused validation-failure diagnosis work, subagents can help keep the main thread compact. The main thread should synthesize their compact findings, not paste their full transcripts.
  - Keep validation evidence bounded. Redirect verbose command output to a local log path such as `.symphony/logs/<timestamp>-<slug>.log`, then record only the command, exit status, duration when available, a short pass/fail summary, and the smallest relevant failure excerpt. Do not paste full test logs, dependency-install output, coverage tables, or build transcripts into the workpad or final response.
  - When a subagent must inspect command output, give it the log path and the exact question; ask it to return a bounded diagnosis with file/line references and the minimal failing excerpt.
  - Keep final ownership in the main thread: decide the plan, supervise edits, run final validation, publish or hand off according to the workflow, and report blockers only when truly blocked.
  """

  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> prepend_operational_guidance()
  end

  @spec operational_guidance() :: String.t()
  def operational_guidance, do: @operational_guidance

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp prepend_operational_guidance(prompt) when is_binary(prompt) do
    if String.contains?(prompt, @operational_guidance_heading) do
      prompt
    else
      @operational_guidance <> "\n" <> String.trim_leading(prompt)
    end
  end
end
