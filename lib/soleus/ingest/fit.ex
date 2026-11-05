defmodule Soleus.Ingest.Fit do
  @moduledoc """
  Decode un fichier FIT Garmin vers la representation interne de Soleus.

  Le travail binaire est delegue a `:fit_file`, un NIF Rust. Ce module ne
  s'occupe que de la traduction : le NIF rend **toutes** les valeurs sous
  forme de chaines, sans typage, et avec les unites brutes de la montre. Tout
  ce qui suit existe pour transformer ca en nombres exploitables.
  """

  alias FitFile.DataRecord

  @typedoc "Une activite decodee, prete a etre persistee."
  @type decoded :: %{
          sport: String.t(),
          started_at: DateTime.t(),
          distance_m: float() | nil,
          moving_time_s: integer() | nil,
          elapsed_time_s: integer() | nil,
          elevation_gain_m: float() | nil,
          calories: integer() | nil,
          avg_hr: integer() | nil,
          max_hr: integer() | nil,
          avg_cadence: float() | nil,
          avg_speed_ms: float() | nil,
          max_speed_ms: float() | nil,
          series: %{atom() => [number() | nil]},
          digest: String.t()
        }

  # Les series temporelles retenues, et les champs FIT qui les portent.
  #
  # Les cles doivent appartenir a `Soleus.Training.Stream.series_keys/0`, qui
  # est la liste canonique : c'est elle qui garantit que les atomes existent
  # au moment de relire un blob. La verification est faite a la compilation
  # juste en dessous, pour qu'un ajout ici ne puisse pas etre oublie la-bas.
  #
  # L'ordre des candidats compte : Garmin ecrit `enhanced_*` avec une plage et
  # une resolution plus larges que les champs historiques du meme nom, qu'il
  # conserve par compatibilite. On prend l'enhanced quand il existe.
  @series_fields [
    distance_m: ["distance"],
    speed_ms: ["enhanced_speed", "speed"],
    altitude_m: ["enhanced_altitude", "altitude"],
    hr: ["heart_rate"],
    cadence: ["cadence"],
    power_w: ["power"],
    temperature_c: ["temperature"],
    lat: ["position_lat"],
    lon: ["position_long"]
  ]

  # Garmin stocke les coordonnees en semicercles : un entier signe 32 bits qui
  # couvre -180..180 degres. Sans cette conversion une latitude parisienne
  # ressemble a 446332520, ce qui n'a aucun sens sur une carte.
  @semicircle_to_deg 180.0 / 2_147_483_648.0

  unknown = Keyword.keys(@series_fields) -- Soleus.Training.Stream.series_keys()

  if unknown != [] do
    raise CompileError,
      description:
        "cles de serie absentes de Soleus.Training.Stream.series_keys/0 : #{inspect(unknown)}"
  end

  @sports %{
    "running" => "run",
    "trail_running" => "run",
    "treadmill_running" => "run",
    "cycling" => "ride",
    "road_biking" => "ride",
    "mountain_biking" => "ride",
    "swimming" => "swim",
    "lap_swimming" => "swim",
    "open_water_swimming" => "swim",
    "walking" => "walk",
    "hiking" => "hike",
    "training" => "strength"
  }

  @doc """
  Decode le fichier FIT situe a `path`.

  Retourne `{:error, reason}` plutot que de lever : l'ingestion traite des
  fichiers venus d'un export de masse, et un fichier corrompu au milieu de
  mille autres ne doit pas interrompre le lot.
  """
  @spec decode(Path.t()) :: {:ok, decoded()} | {:error, term()}
  def decode(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, records} <- FitFile.from_binary(raw) do
      build(records, digest(raw))
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_parser_result, other}}
    end
  end

  @doc "Empreinte SHA-256 du contenu, utilisee comme cle d'idempotence."
  @spec digest(binary()) :: String.t()
  def digest(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  # -- construction -----------------------------------------------------------

  defp build(records, digest) do
    points = Enum.filter(records, &(&1.kind == "record"))
    session = Enum.find(records, &(&1.kind == "session"))

    if activity?(session, points) do
      build_activity(records, session, points, digest)
    else
      {:error, :not_an_activity}
    end
  end

  # Duree au dela de laquelle un fichier ne decrit plus une seance. Garmin
  # produit des fichiers d'accumulation marques `generic` qui portent un
  # message `session` en bonne et due forme, mais couvrent plusieurs jours :
  # sur un export reel, l'un d'eux totalise 893 km en 5,2 jours a 0,3 m/s.
  #
  # Ils passaient donc le filtre et entraient en base comme des seances. La
  # consequence n'etait pas anodine : leur duree produisait une charge
  # d'entrainement de plusieurs milliers de points, qui ecrasait la courbe de
  # forme de toute la periode.
  @max_session_s 24 * 3600

  # Un export Garmin complet contient surtout des fichiers qui ne sont pas des
  # seances : suivi quotidien, variabilite cardiaque nocturne, sauvegardes de
  # reglages. Sur 8 675 fichiers d'un export reel, 131 seulement sont des
  # activites.
  #
  # Le marqueur principal est le message `session`, que seule une activite
  # porte. La tolerance sur `record` garde le cas des fichiers reconstruits ou
  # produits par un appareil tiers, qui ont des points sans resume de seance.
  defp activity?(session, points) do
    (not is_nil(session) or length(points) > 1) and plausible_duration?(session)
  end

  defp plausible_duration?(nil), do: true

  defp plausible_duration?(session) do
    case num(session, "total_elapsed_time") || num(session, "total_timer_time") do
      nil -> true
      elapsed -> elapsed <= @max_session_s
    end
  end

  defp build_activity(records, session, points, digest) do
    case started_at(session, points) do
      nil ->
        {:error, :no_timestamp}

      start ->
        series = series(points, start)

        {:ok,
         %{
           sport: sport(session, records),
           started_at: start,
           distance_m: total_distance(session, series),
           moving_time_s: num(session, "total_timer_time") |> round_or_nil(),
           elapsed_time_s: elapsed(session, series),
           elevation_gain_m: elevation_gain(session, series),
           calories: num(session, "total_calories") |> round_or_nil(),
           avg_hr:
             num(session, "avg_heart_rate") |> round_or_nil() ||
               mean_of(series[:hr]) |> round_or_nil(),
           max_hr:
             num(session, "max_heart_rate") |> round_or_nil() ||
               max_of(series[:hr]) |> round_or_nil(),
           avg_cadence: num(session, "avg_cadence") || mean_of(series[:cadence]),
           avg_speed_ms: avg_speed(session, series),
           max_speed_ms:
             num(session, "enhanced_max_speed") || num(session, "max_speed") ||
               max_of(series[:speed_ms]),
           series: series,
           digest: digest
         }}
    end
  end

  # Le champ `sport` vit soit dans la session, soit dans un message `sport`
  # dedie selon le modele de montre et la version du SDK.
  defp sport(session, records) do
    raw =
      value(session, "sport") ||
        records
        |> Enum.find(&(&1.kind == "sport"))
        |> value("sport")

    # Repli sur "unknown" et non sur la valeur brute : un export Garmin contient
    # des sports que cette table ne connait pas ("generic" pour les fichiers
    # d'accumulation multi-jours, par exemple), et laisser passer la chaine
    # telle quelle faisait echouer la validation du changeset plus loin. Un
    # sport non reconnu n'est pas une raison de perdre la seance.
    case raw do
      nil -> "unknown"
      sport -> Map.get(@sports, sport, "unknown")
    end
  end

  # Le depart vient de la session quand elle existe, sinon du premier point.
  defp started_at(session, points) do
    datetime(session, "start_time") || points |> List.first() |> datetime("timestamp")
  end

  # -- series -----------------------------------------------------------------

  # Une seule passe sur les points produit toutes les series d'un coup, et
  # chaque serie garde la meme longueur que `points` : un capteur qui decroche
  # laisse un `nil` a sa place plutot que de desaligner l'axe du temps.
  defp series([], _start), do: %{t: []}

  defp series(points, start) do
    base = %{t: Enum.map(points, &offset_seconds(&1, start))}

    Enum.reduce(@series_fields, base, fn {key, candidates}, acc ->
      column = Enum.map(points, &extract(&1, key, candidates))

      if Enum.any?(column, &(&1 != nil)), do: Map.put(acc, key, column), else: acc
    end)
  end

  defp offset_seconds(point, start) do
    case datetime(point, "timestamp") do
      nil -> nil
      at -> DateTime.diff(at, start)
    end
  end

  defp extract(point, key, candidates) do
    candidates
    |> Enum.find_value(&DataRecord.get_field_value(point, &1))
    |> to_number()
    |> convert(key)
  end

  defp convert(nil, _key), do: nil
  defp convert(v, :lat), do: v * @semicircle_to_deg
  defp convert(v, :lon), do: v * @semicircle_to_deg
  defp convert(v, _key), do: v

  # -- totaux, avec repli sur les series --------------------------------------
  #
  # Les montres d'entree de gamme et certains fichiers reconstruits n'ecrivent
  # pas de message `session`. Chaque total sait donc se recalculer depuis les
  # points, pour que le reste de l'application n'ait jamais a distinguer les
  # deux cas.

  defp total_distance(session, series) do
    num(session, "total_distance") || last_of(series[:distance_m])
  end

  defp elapsed(session, series) do
    (num(session, "total_elapsed_time") || last_of(series[:t])) |> round_or_nil()
  end

  defp avg_speed(session, series) do
    num(session, "enhanced_avg_speed") || num(session, "avg_speed") ||
      derived_avg_speed(series)
  end

  defp derived_avg_speed(series) do
    with d when is_number(d) <- last_of(series[:distance_m]),
         t when is_number(t) and t > 0 <- last_of(series[:t]) do
      d / t
    else
      _ -> nil
    end
  end

  defp elevation_gain(session, series) do
    num(session, "total_ascent") || derived_elevation_gain(series[:altitude_m])
  end

  defp derived_elevation_gain(nil), do: nil

  defp derived_elevation_gain(altitudes) do
    # Seuil de 0,5 m sur chaque montee elementaire : le bruit du barometre fait
    # osciller l'altitude de quelques decimetres a l'arret, et sommer ces
    # oscillations brutes donne des centaines de metres de D+ sur du plat.
    altitudes
    |> Enum.reject(&is_nil/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [a, b], acc ->
      delta = b - a
      if delta > 0.5, do: acc + delta, else: acc
    end)
  end

  # -- primitives -------------------------------------------------------------

  defp value(nil, _name), do: nil
  defp value(record, name), do: DataRecord.get_field_value(record, name)

  defp num(record, name), do: record |> value(name) |> to_number()

  defp datetime(record, name) do
    case value(record, name) do
      nil ->
        nil

      raw ->
        case DateTime.from_iso8601(raw) do
          {:ok, at, _offset} -> DateTime.truncate(at, :second)
          _ -> nil
        end
    end
  end

  defp to_number(nil), do: nil

  defp to_number(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(raw) do
          {float, ""} -> float
          _ -> nil
        end
    end
  end

  defp to_number(raw) when is_number(raw), do: raw
  defp to_number(_), do: nil

  defp round_or_nil(nil), do: nil
  defp round_or_nil(n) when is_number(n), do: round(n)

  defp last_of(nil), do: nil
  defp last_of(list), do: list |> Enum.reject(&is_nil/1) |> List.last()

  defp max_of(nil), do: nil

  defp max_of(list) do
    case Enum.reject(list, &is_nil/1) do
      [] -> nil
      vals -> Enum.max(vals)
    end
  end

  defp mean_of(nil), do: nil

  defp mean_of(list) do
    case Enum.reject(list, &is_nil/1) do
      [] -> nil
      vals -> Enum.sum(vals) / length(vals)
    end
  end
end
