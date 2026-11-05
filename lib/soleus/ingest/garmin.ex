defmodule Soleus.Ingest.Garmin do
  @moduledoc """
  Client de l'API personnelle Garmin Connect.

  Les chemins et la forme des reponses suivent le client de reference publie
  par Garmin (`garmin/connect-personal-api-python`, Apache 2.0), qui est la
  seule source publique a les documenter : la FAQ du programme renvoie vers
  une documentation Swagger servie par une application JavaScript.

  ## Le flux

      cle personnelle -> jeton (24 h) -> recherche d'activites
                                      -> telechargement du fichier d'origine
                                      -> import par le pipeline existant

  Le fichier d'origine est telecharge plutot que le resume JSON : c'est la
  meme donnee que l'export RGPD, donc le meme decodeur, les memes metriques,
  et l'idempotence par empreinte fonctionne entre les deux sources. Une
  activite deja importee depuis l'export ne sera pas dupliquee par l'API.

  ## Ce que l'API ne fait pas

  Pas de webhook : il faut interroger. Et le backfill d'un nouveau compte se
  limite a une trentaine de jours, ce qui rend l'export RGPD indispensable
  pour amorcer l'historique — l'API ne sert qu'a l'incremental.
  """

  require Logger

  alias Soleus.Ingest.Garmin.Token

  @base_url "https://personal.connectapi.garmin.com"

  # Chemins repris du client de reference Garmin.
  @search_path "/activitylist-service/activities/search/activities"
  @activity_path "/activity-service/activity"
  @download_path "/download-service/files/activity"
  @hr_zones_path "/biometric-service/heartRateZones/v2"
  @profile_path "/userprofile-service/userprofile/settings"

  @doc "URL de base, surchargeable pour les tests."
  def base_url, do: Application.get_env(:soleus, :garmin_base_url, @base_url)

  @doc """
  Requete GET authentifiee.

  Un 401 declenche un unique nouvel echange de jeton puis une seule reprise :
  le jeton a pu expirer entre la verification d'echeance et l'arrivee de la
  requete chez Garmin. Au dela on abandonne — marteler l'API avec une cle
  revoquee ne la rendrait pas valide.
  """
  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(path, opts \\ []), do: request(path, opts, true)

  defp request(path, opts, retry?) do
    case Token.fetch() do
      {:ok, token} -> send_get(token, path, opts, retry?)
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_get(token, path, opts, retry?) do
    [
      url: base_url() <> path,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", Keyword.get(opts, :accept, "application/json")}
      ],
      params: Keyword.get(opts, :params, []),
      decode_body: Keyword.get(opts, :decode_body, true),
      receive_timeout: Keyword.get(opts, :timeout, 60_000)
    ]
    |> Req.get()
    |> handle(path, opts, retry?)
  end

  defp handle({:ok, %{status: status, body: body}}, _path, _opts, _retry?)
       when status in 200..299,
       do: {:ok, body}

  defp handle({:ok, %{status: 401}}, path, opts, true) do
    Token.invalidate()
    request(path, opts, false)
  end

  defp handle({:ok, %{status: 401}}, _path, _opts, false), do: {:error, :api_key_rejected}
  defp handle({:ok, %{status: 403}}, _path, _opts, _retry?), do: {:error, :api_key_rejected}
  defp handle({:ok, %{status: 404}}, path, _opts, _retry?), do: {:error, {:not_found, path}}
  defp handle({:ok, %{status: 429}}, _path, _opts, _retry?), do: {:error, :rate_limited}

  defp handle({:ok, %{status: status, body: body}}, _path, _opts, _retry?),
    do: {:error, {:unexpected_status, status, body}}

  defp handle({:error, reason}, _path, _opts, _retry?), do: {:error, {:transport, reason}}

  # -- activites --------------------------------------------------------------

  @doc """
  Liste les activites d'une plage de dates.

  La pagination est a offset et non a curseur : `start` est un rang. Sans
  consequence ici, une seule personne alimentant ce compte, et l'import etant
  idempotent de toute facon.
  """
  @spec search_activities(Date.t(), Date.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search_activities(from, to, opts \\ []) do
    params = [
      startDate: Date.to_iso8601(from),
      endDate: Date.to_iso8601(to),
      start: Keyword.get(opts, :offset, 0),
      limit: Keyword.get(opts, :limit, 100)
    ]

    case get(@search_path, params: params) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, %{"activities" => list}} when is_list(list) -> {:ok, list}
      {:ok, nil} -> {:ok, []}
      {:ok, other} -> {:error, {:unexpected_body, other}}
      error -> error
    end
  end

  @doc "Resume detaille d'une activite."
  @spec get_activity(integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def get_activity(activity_id), do: get("#{@activity_path}/#{activity_id}")

  @doc """
  Telecharge le fichier d'origine d'une activite et l'ecrit sur disque.

  Garmin rend une **archive ZIP**, pas un `.fit` nu — y compris pour une
  activite unique. Le decompresser ici evite que chaque appelant ait a
  connaitre ce detail, et rend un chemin directement utilisable par
  `Soleus.Training.import_fit/2`.
  """
  @spec download_activity(integer() | String.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def download_activity(activity_id, dir) do
    opts = [
      accept: "application/zip, application/x-zip-compressed, application/octet-stream",
      decode_body: false,
      timeout: 120_000
    ]

    with {:ok, archive} <- get("#{@download_path}/#{activity_id}", opts),
         {:ok, {name, contents}} <- first_fit(archive),
         :ok <- File.mkdir_p(dir),
         target = Path.join(dir, filename(activity_id, name)),
         :ok <- File.write(target, contents) do
      {:ok, target}
    end
  end

  # L'archive ne contient normalement qu'un fichier, mais rien ne le garantit.
  # On prend le premier `.fit` plutot que le premier fichier tout court.
  defp first_fit(archive) when is_binary(archive) do
    case :zip.extract(archive, [:memory]) do
      {:ok, entries} ->
        entries
        |> Enum.find(fn {name, _contents} -> name |> to_string() |> String.ends_with?(".fit") end)
        |> case do
          nil -> {:error, :no_fit_in_archive}
          {name, contents} -> {:ok, {to_string(name), contents}}
        end

      {:error, reason} ->
        {:error, {:bad_archive, reason}}
    end
  end

  defp first_fit(_other), do: {:error, :not_an_archive}

  # Le nom porte l'identifiant Garmin : deux activites ne peuvent pas se
  # recouvrir dans le dossier d'import, et le fichier reste tracable.
  defp filename(activity_id, _name), do: "garmin_#{activity_id}.fit"

  # -- profil -----------------------------------------------------------------

  @doc "Zones de frequence cardiaque, dont la FC max retenue par Garmin."
  @spec heart_rate_zones() :: {:ok, term()} | {:error, term()}
  def heart_rate_zones, do: get(@hr_zones_path)

  @doc "Reglages du profil utilisateur."
  @spec profile_settings() :: {:ok, term()} | {:error, term()}
  def profile_settings, do: get(@profile_path)
end
