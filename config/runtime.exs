import Config

# Dev convenience: load `crowd/.env` (simple KEY=value lines) into the OS
# environment so CF_ACCOUNT_ID / CF_API_TOKEN / ANTHROPIC_API_KEY are available to
# the bots without `export`. The file is gitignored. In production (Fly, etc.) set
# real env vars and skip the file.
env_file = Path.expand("../.env", __DIR__)

if File.exists?(env_file) do
  env_file
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.each(fn line ->
    line = String.trim(line)

    unless line == "" or String.starts_with?(line, "#") do
      # tolerate an optional leading `export ` so the same file can be `source`d
      case line |> String.replace_prefix("export ", "") |> String.split("=", parts: 2) do
        [k, v] ->
          System.put_env(String.trim(k), v |> String.trim() |> String.trim("\"") |> String.trim("'"))

        _ ->
          :ok
      end
    end
  end)
end
