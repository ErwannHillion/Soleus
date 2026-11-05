defmodule Soleus.Config do
  @moduledoc """
  Point d'acces unique a la configuration applicative.

  Le check `.credo/no_direct_application_get_env.ex` interdit
  `Application.get_env(:soleus, ...)` ailleurs que dans ce module et dans
  `Soleus.Application`. La raison est pratique plutot que dogmatique : une cle
  lue a six endroits differents n'a nulle part de valeur par defaut unique, et
  chaque appelant finit par en inventer une legerement differente. Ici, chaque
  reglage a un nom de fonction, un type de retour et un defaut, en un seul
  endroit.
  """

  @doc """
  Cle d'API personnelle Garmin Connect.

  Rend `nil` quand elle n'est pas configuree, ce qui est l'etat normal avant la
  premiere mise en place : l'import de fichiers FIT fonctionne sans.
  """
  @spec garmin_api_key() :: String.t() | nil
  def garmin_api_key, do: get(:garmin_api_key)

  @doc """
  Dossier surveille pour l'import des fichiers FIT.

  C'est la qu'on depose un export Garmin decompresse.

  Le chemin est relatif au repertoire courant, et non derive de
  `:code.priv_dir/1` : en developpement, `priv` dans le repertoire de build
  n'est qu'un lien symbolique, et les chemins conserves en base pointeraient
  vers `_build`, que `mix clean` efface.
  """
  @spec fit_import_dir() :: Path.t()
  def fit_import_dir, do: get(:fit_import_dir, "priv/import")

  @doc """
  Sport par defaut du tableau de bord.

  Les modeles physiologiques de Soleus sont cales sur la course a pied ; les
  autres sports sont stockes mais pas modelises.
  """
  @spec default_sport() :: String.t()
  def default_sport, do: get(:default_sport, "run")

  defp get(key, default \\ nil), do: Application.get_env(:soleus, key, default)
end
