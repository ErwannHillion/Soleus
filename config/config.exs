# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :soleus,
  ecto_repos: [Soleus.Repo],
  generators: [timestamp_type: :utc_datetime]

# Files separees parce que leurs profils ne se ressemblent pas : `ingestion`
# fait du travail long et sequentiel (decodage FIT, appels API), `analytics`
# du calcul court et parallelisable. Les melanger laisserait un import de
# masse bloquer le recalcul de la courbe de forme.
config :soleus, Oban,
  repo: Soleus.Repo,
  queues: [ingestion: 2, analytics: 4],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       # Ajustement quotidien des modeles, un peu apres minuit : la fenetre
       # glissante de 90 jours bouge chaque jour, meme sans nouvelle seance.
       # Synchronisation Garmin au petit matin, avant l'ajustement : les
       # seances de la veille sont alors deja en base quand les modeles se
       # recalculent.
       {"10 0 * * *", Soleus.Workers.SyncGarmin},
       {"20 0 * * *", Soleus.Workers.FitModels}
     ]}
  ]

# Configure the endpoint
config :soleus, SoleusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SoleusWeb.ErrorHTML, json: SoleusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Soleus.PubSub,
  live_view: [signing_salt: "Is9QfYke"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :soleus, Soleus.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  soleus: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  soleus: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
