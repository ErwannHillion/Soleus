defmodule Soleus.Training.Athlete do
  @moduledoc """
  Les constantes physiologiques de l'athlete, en une seule ligne.

  Seul `sex` est obligatoire, parce que le TRIMP de Banister a des
  coefficients differents selon le sexe. Tout le reste est optionnel et se
  deduit de l'historique quand c'est possible.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "athlete" do
    field :name, :string
    field :sex, :string, default: "male"
    field :birth_date, :date
    field :weight_kg, :float
    field :hr_max, :integer
    field :hr_rest, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(athlete, attrs) do
    athlete
    |> cast(attrs, [:name, :sex, :birth_date, :weight_kg, :hr_max, :hr_rest])
    |> validate_inclusion(:sex, ~w(male female))
    |> validate_number(:hr_max, greater_than: 100, less_than: 250)
    |> validate_number(:hr_rest, greater_than: 25, less_than: 100)
    |> validate_number(:weight_kg, greater_than: 20, less_than: 250)
  end

  @doc "Age en annees pleines a la date donnee, ou nil si la naissance est inconnue."
  def age(%__MODULE__{birth_date: nil}, _on), do: nil

  def age(%__MODULE__{birth_date: born}, on) do
    years = on.year - born.year
    if Date.compare(%{born | year: on.year}, on) == :gt, do: years - 1, else: years
  end
end
