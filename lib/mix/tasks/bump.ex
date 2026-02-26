defmodule Mix.Tasks.Bump do
  @moduledoc false

  use Mix.Task

  @shortdoc "Bump version, update changelog, commit and tag"

  @impl Mix.Task
  def run(args) do
    bump_type = parse_args(args)
    current_version = read_version()
    new_version = bump_version(current_version, bump_type)

    Mix.shell().info("Bumping version: #{current_version} -> #{new_version}")

    write_version(new_version)
    update_changelog(new_version)

    Mix.shell().info("Committing changes...")
    System.cmd("git", ["add", "VERSION", "CHANGELOG.md"])
    System.cmd("git", ["commit", "-m", "Release v#{new_version}"])

    Mix.shell().info("Creating tag v#{new_version}...")
    System.cmd("git", ["tag", "v#{new_version}"])

    Mix.shell().info("""

    Release v#{new_version} prepared!

    Next steps:
      git push origin main --tags
    """)
  end

  defp parse_args([]), do: :patch
  defp parse_args(["patch"]), do: :patch
  defp parse_args(["minor"]), do: :minor
  defp parse_args(["major"]), do: :major

  defp parse_args(_) do
    Mix.raise("Usage: mix bump [patch|minor|major]")
  end

  defp read_version do
    "VERSION"
    |> File.read!()
    |> String.trim()
  end

  defp write_version(version) do
    File.write!("VERSION", version <> "\n")
  end

  defp bump_version(version, bump_type) do
    [major, minor, patch] =
      version
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)

    case bump_type do
      :patch -> "#{major}.#{minor}.#{patch + 1}"
      :minor -> "#{major}.#{minor + 1}.0"
      :major -> "#{major + 1}.0.0"
    end
  end

  defp update_changelog(new_version) do
    changelog = File.read!("CHANGELOG.md")
    today = Date.utc_today() |> Date.to_iso8601()
    prs = get_merged_prs_since_last_tag()

    pr_list =
      case prs do
        [] ->
          "- No PRs merged\n"

        prs ->
          Enum.map_join(prs, "\n", fn {number, title} -> "- #{title} (##{number})" end) <> "\n"
      end

    new_section = """
    ## [v#{new_version}] - #{today}

    #{pr_list}
    """

    # Insert after the header (first ## line marks the start of versions)
    updated =
      case String.split(changelog, ~r/^## \[v/m, parts: 2) do
        [header, rest] ->
          header <> new_section <> "## [v" <> rest

        [_only_header] ->
          changelog <> "\n" <> new_section
      end

    File.write!("CHANGELOG.md", updated)
  end

  defp get_merged_prs_since_last_tag do
    case System.cmd("git", ["describe", "--tags", "--abbrev=0"], stderr_to_stdout: true) do
      {tag, 0} ->
        last_tag = String.trim(tag)
        {date, 0} = System.cmd("git", ["log", "-1", "--format=%cs", last_tag])
        fetch_merged_prs(String.trim(date))

      _ ->
        # No tags yet, get all merged PRs
        fetch_merged_prs(nil)
    end
  end

  defp fetch_merged_prs(since_date) do
    args =
      [
        "pr",
        "list",
        "--state",
        "merged",
        "--json",
        "number,title",
        "--jq",
        ".[] | \"\\(.number)\\t\\(.title)\""
      ] ++
        if(since_date, do: ["--search", "merged:>=#{since_date}"], else: [])

    case System.cmd("gh", args) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          [number, title] = String.split(line, "\t", parts: 2)
          {number, title}
        end)

      _ ->
        []
    end
  end
end
