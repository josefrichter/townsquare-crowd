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
          System.put_env(
            String.trim(k),
            v |> String.trim() |> String.trim("\"") |> String.trim("'")
          )

        _ ->
          :ok
      end
    end
  end)
end

# Production overrides (Fly sets these as real env vars; locally they're just
# unset and the config.exs defaults above stand).
if ws = System.get_env("TOWNSQUARE_WS_URL") do
  config :town_crowd, townsquare_ws: ws
end

if origin = System.get_env("TOWNSQUARE_ORIGIN") do
  config :town_crowd, townsquare_origin: origin
end

if port = System.get_env("PORT") do
  config :town_crowd, port: String.to_integer(port)
end

# Cluster the Fly machines this app runs on (2, for zero-downtime deploys) over
# Fly's private 6PN network, polling `<app>.internal` for sibling addresses.
# FLY_APP_NAME only exists inside a deployed Fly machine — locally/in CI this is
# skipped and the app just runs as a single, unclustered node (same as before
# libcluster existed).
if fly_app = System.get_env("FLY_APP_NAME") do
  config :libcluster,
    topologies: [
      fly6pn: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [
          polling_interval: 2_000,
          query: "#{fly_app}.internal",
          node_basename: "town_crowd"
        ]
      ]
    ]
end
