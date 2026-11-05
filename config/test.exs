import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :soleus, Soleus.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("POSTGRES_PORT") || "5436"),
  database: "soleus_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :soleus, SoleusWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4007],
  secret_key_base: "5DtrZD85khnieE1x0KHo7ClSzOop199ygGLq+POq1OGoLir0SSyV7TUYlu2t3pwO",
  server: false

# Oban en mode manuel pendant les tests : les jobs ne partent pas tout seuls,
# et chaque test declenche ce qu'il veut verifier.
config :soleus, Oban, testing: :manual

# In test we don't send emails
config :soleus, Soleus.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
