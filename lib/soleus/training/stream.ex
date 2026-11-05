defmodule Soleus.Training.Stream do
  @moduledoc """
  Les series point par point d'une activite, dans un seul blob compresse.

  Le format est un terme Erlang compresse plutot que du JSON ou une ligne par
  echantillon. Les trois raisons, dans l'ordre d'importance :

    * une ligne par point donnerait une table a dizaines de millions de lignes
      pour quelques annees d'historique, pour une donnee qu'on lit toujours en
      entier et jamais a l'unite ;
    * `term_to_binary/2` conserve les types et les `nil` des capteurs qui
      decrochent, la ou JSON transforme les entiers en flottants ;
    * la compression tombe autour de 10x sur des series de capteurs, qui sont
      tres redondantes d'un point au suivant.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # 9 et non le defaut 6 : l'ecriture a lieu une fois a l'ingestion, la lecture
  # des milliers de fois. Quelques millisecondes de plus a la compression pour
  # un blob plus petit a chaque lecture, c'est le bon cote du compromis.
  @compression 9

  # Les seules cles qu'une serie peut porter, declarees **ici** et pas ailleurs.
  #
  # Cette liste n'est pas de la documentation, elle est fonctionnelle.
  # `binary_to_term/2` en mode `:safe` refuse les atomes qui n'existent pas
  # encore dans la machine virtuelle. Si les cles n'etaient nommees que dans le
  # module de decodage FIT, le succes du decodage dependrait de l'ordre de
  # chargement des modules : un appelant qui n'a pas encore touche a
  # `Soleus.Ingest.Fit` echouerait, l'autre passerait. Les declarer dans le
  # module qui decode garantit que les atomes existent des que `decode/1` peut
  # etre appelee.
  @series_keys [
    :t,
    :distance_m,
    :speed_ms,
    :altitude_m,
    :hr,
    :cadence,
    :power_w,
    :temperature_c,
    :lat,
    :lon
  ]

  schema "activity_streams" do
    belongs_to :activity, Soleus.Training.Activity

    field :sample_count, :integer
    field :available, {:array, :string}, default: []
    field :series, :binary

    timestamps(type: :utc_datetime)
  end

  @doc """
  Construit le changeset depuis une map de series decodees.

  `series` est la forme rendue par `Soleus.Ingest.Fit.decode/1` :
  `%{t: [0, 1, 2], hr: [120, 121, nil], ...}`.
  """
  def changeset(stream, %{activity_id: activity_id, series: series}) do
    stream
    |> cast(%{activity_id: activity_id}, [:activity_id])
    |> put_change(:series, encode(series))
    |> put_change(:sample_count, series |> Map.get(:t, []) |> length())
    |> put_change(:available, series |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort())
    |> validate_required([:activity_id, :series, :sample_count])
    |> unique_constraint(:activity_id)
    |> foreign_key_constraint(:activity_id)
  end

  @doc "Les cles de serie reconnues."
  @spec series_keys() :: [atom()]
  def series_keys, do: @series_keys

  @doc """
  Serialise une map de series vers le blob stocke.

  Leve si une cle inconnue se presente. C'est voulu : une cle qui passerait a
  l'ecriture sans figurer dans `@series_keys` produirait un blob qu'on ne
  saurait plus relire en mode `:safe`, et l'echec arriverait des mois plus
  tard a la lecture, loin de sa cause.
  """
  @spec encode(map()) :: binary()
  def encode(series) when is_map(series) do
    case Map.keys(series) -- @series_keys do
      [] -> :erlang.term_to_binary(series, compressed: @compression)
      unknown -> raise ArgumentError, "cles de serie inconnues : #{inspect(unknown)}"
    end
  end

  @doc """
  Relit les series d'un enregistrement.

  `:safe` est conserve meme si la donnee vient de notre propre ecriture : c'est
  la ceinture qui empeche un blob altere de creer des atomes arbitraires, et
  les atomes legitimes sont garantis par `@series_keys` juste au dessus.
  """
  @spec decode(t :: %__MODULE__{} | binary()) :: map()
  def decode(%__MODULE__{series: blob}), do: decode(blob)
  def decode(blob) when is_binary(blob), do: :erlang.binary_to_term(blob, [:safe])
end
