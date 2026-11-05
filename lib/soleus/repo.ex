defmodule Soleus.Repo do
  use Ecto.Repo,
    otp_app: :soleus,
    adapter: Ecto.Adapters.Postgres
end
