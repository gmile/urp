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
    {_, 0} = System.cmd("git", ["add", "VERSION", "CHANGELOG.md"])
    {_, 0} = System.cmd("git", ["commit", "-m", "Release v#{new_version}"])

    Mix.shell().info("Creating tag v#{new_version}...")
    {_, 0} = System.cmd("git", ["tag", "-m", "v#{new_version}", "v#{new_version}"])

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

    updated = String.replace(changelog, "## [Unreleased]", "## [v#{new_version}] - #{today}")

    if updated == changelog do
      Mix.raise("No [Unreleased] section found in CHANGELOG.md — add one before bumping")
    end

    File.write!("CHANGELOG.md", updated)
  end
end
