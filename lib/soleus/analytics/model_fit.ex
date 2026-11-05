defmodule Soleus.Analytics.ModelFit do
  @moduledoc """
  L'etat du modele physiologique a une date donnee.

  Une ligne par jour et par fenetre d'ajustement. Garder l'historique des
  ajustements, au lieu de n'avoir que le dernier, est ce qui rend la
  projection possible : c'est la pente de `cs_ms` sur les derniers mois qui
  dit si la forme progresse, et a quelle vitesse.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "model_fits" do
    field :fitted_on, :date
    field :sport, :string
    field :window_days, :integer

    field :cs_ms, :float
    field :d_prime_m, :float
    field :r2, :float
    field :sample_count, :integer

    field :vdot, :float
    field :endurance_exponent, :float
    field :exponent_source, :string
    field :predictions, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(fit, attrs) do
    fit
    |> cast(attrs, [
      :fitted_on,
      :sport,
      :window_days,
      :cs_ms,
      :d_prime_m,
      :r2,
      :sample_count,
      :vdot,
      :endurance_exponent,
      :exponent_source,
      :predictions
    ])
    |> validate_required([:fitted_on, :sport, :window_days])
    |> validate_number(:cs_ms, greater_than: 0)
    |> unique_constraint([:fitted_on, :sport, :window_days])
  end
end
