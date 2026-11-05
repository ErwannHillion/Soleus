defmodule Soleus.Ingest.Garmin.Token do
  @moduledoc """
  Gere le jeton d'acces de l'API personnelle Garmin.

  ## Le probleme que ce module resout

  Garmin n'emet **pas de jeton de rafraichissement**. Le cycle est :

      cle personnelle  --(POST, en-tete ApiKey)-->  jeton d'acces (24 h)

  La cle, elle, expire au bout de 30, 90, 180 ou 365 jours au choix, et n'est
  affichee qu'une seule fois a sa creation. Il n'y en a qu'une active par
  compte.

  Consequences concretes, et c'est pour elles que ce module existe :

    * un jeton garde en configuration serait perime le lendemain. Il faut donc
      l'echanger a la demande et le conserver en memoire ;
    * sans rafraichissement, le seul recours sur expiration est de refaire
      l'echange. On le fait **avant** l'echeance plutot qu'en reaction a un
      401, pour ne pas perdre une requete au passage ;
    * quand c'est la **cle** qui expire, aucun echange ne peut aboutir. Ce cas
      doit remonter avec un message qui dit quoi faire, et non se confondre
      avec une panne reseau : la seule issue est que l'athlete regenere une
      cle a la main sur Garmin Connect.

  Le jeton vit dans un processus et jamais sur disque : il n'a aucune valeur
  passe vingt-quatre heures, et le rendre persistant n'ajouterait qu'une
  surface de fuite.
  """

  use GenServer

  require Logger

  alias Soleus.Config

  @token_url "https://personal.connectapi.garmin.com/personalapitoken-service/personal-api/personal-api-key/token"

  # On renouvelle une heure avant l'echeance declaree par le jeton. C'est la
  # marge retenue par le client de reference de Garmin, nettement plus large
  # que ce qu'une requete lente exigerait : elle met aussi a l'abri d'un ecart
  # d'horloge entre cette machine et celle de Garmin.
  @renew_margin_s 3600

  @type t :: {:ok, String.t()} | {:error, term()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Rend un jeton valide, en l'echangeant si besoin.

  Serialise par le GenServer : dix jobs Oban qui demarrent ensemble ne
  declenchent qu'un seul echange.
  """
  @spec fetch() :: t()
  def fetch(server \\ __MODULE__), do: GenServer.call(server, :fetch, 30_000)

  @doc "Oublie le jeton en cache. Utile apres un 401 inattendu."
  @spec invalidate() :: :ok
  def invalidate(server \\ __MODULE__), do: GenServer.cast(server, :invalidate)

  @doc "L'URL d'echange, exposee pour les tests et le diagnostic."
  def token_url, do: @token_url

  @impl GenServer
  def init(_opts), do: {:ok, %{token: nil, expires_at: nil}}

  @impl GenServer
  def handle_call(:fetch, _from, state) do
    if valid?(state) do
      {:reply, {:ok, state.token}, state}
    else
      case exchange() do
        {:ok, token, expires_at} ->
          {:reply, {:ok, token}, %{token: token, expires_at: expires_at}}

        {:error, reason} ->
          {:reply, {:error, reason}, %{token: nil, expires_at: nil}}
      end
    end
  end

  @impl GenServer
  def handle_cast(:invalidate, _state), do: {:noreply, %{token: nil, expires_at: nil}}

  defp valid?(%{token: nil}), do: false

  defp valid?(%{expires_at: nil}), do: false

  defp valid?(%{expires_at: expires_at}) do
    DateTime.diff(expires_at, DateTime.utc_now()) > @renew_margin_s
  end

  defp exchange do
    case Config.garmin_api_key() do
      nil -> {:error, :no_api_key}
      key -> post_token(key)
    end
  end

  defp post_token(key) do
    case Req.post(@token_url,
           headers: [{"authorization", "ApiKey #{key}"}],
           receive_timeout: 20_000
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        read_token(body)

      # 401 et 403 ne sont pas des pannes : la cle est perimee ou revoquee, et
      # aucune reprise automatique n'est possible. Le message doit dire ou
      # aller la regenerer.
      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :api_key_rejected}

      {:ok, %{status: status, body: body}} ->
        {:error, {:unexpected_status, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp read_token(body) do
    case token_string(body) do
      nil -> {:error, {:unexpected_body, body}}
      token -> {:ok, token, expiry_of(token)}
    end
  end

  # La forme exacte de la reponse n'est pas publiee. On accepte donc les
  # tournures usuelles plutot que d'en supposer une seule, et on echoue
  # franchement si aucune ne correspond.
  defp token_string(body) when is_binary(body), do: body |> String.trim() |> presence()

  defp token_string(%{} = body) do
    Enum.find_value(["access_token", "accessToken", "token", "jwt"], &presence(body[&1]))
  end

  defp token_string(_body), do: nil

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_value), do: nil

  # L'echeance se lit dans la charge utile du jeton plutot que de supposer
  # vingt-quatre heures : si Garmin raccourcit la duree de vie, le code suit
  # sans modification.
  #
  # La signature n'est pas verifiee, et ce n'est pas un oubli : le jeton vient
  # d'etre recu de Garmin sur une connexion TLS, et il n'est pas utilise ici
  # comme preuve d'identite mais seulement lu pour savoir quand le renouveler.
  defp expiry_of(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} <- Jason.decode(json),
         {:ok, at} <- DateTime.from_unix(exp) do
      at
    else
      _other ->
        # Jeton opaque, ou charge utile illisible. On retombe sur la duree
        # annoncee par Garmin, en la raccourcissant d'une heure par prudence.
        Logger.debug("jeton Garmin sans echeance lisible, repli sur 23 h")
        DateTime.add(DateTime.utc_now(), 23 * 3600, :second)
    end
  end

  @doc """
  Message lisible d'un echec d'authentification.
  """
  @spec explain(term()) :: String.t()
  def explain(:no_api_key),
    do:
      "Aucune cle Garmin configuree. En creer une sur " <>
        "https://connect.garmin.com/app/settings/personalApiToken " <>
        "puis renseigner GARMIN_API_KEY."

  def explain(:api_key_rejected),
    do:
      "Cle Garmin refusee : elle est expiree ou revoquee. Garmin n'emet pas de " <>
        "jeton de rafraichissement, il faut en regenerer une sur " <>
        "https://connect.garmin.com/app/settings/personalApiToken"

  def explain({:transport, reason}), do: "Garmin injoignable : #{inspect(reason)}"
  def explain({:unexpected_status, status, _body}), do: "Reponse inattendue de Garmin : #{status}"
  def explain(other), do: "Echec d'authentification Garmin : #{inspect(other)}"
end
