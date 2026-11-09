defmodule Soleus.Analytics.Zones do
  @moduledoc """
  Zones de frequence cardiaque derivees des efforts de l'athlete.

  ## Pourquoi ne pas se contenter de celles de la montre

  Garmin decoupe par pourcentage de frequence maximale, aux paliers 50, 60,
  70, 80 et 90 %. Deux problemes, et le second est le plus serieux.

  **La frequence maximale retenue n'est pas toujours la bonne.** Elle vient
  d'une saisie ou d'une formule, et elle decale tout le decoupage quand elle
  est fausse.

  **Surtout, le pourcentage de frequence maximale est un mauvais repere.**
  Deux coureurs de meme frequence maximale peuvent avoir des seuils separes
  de quinze battements. Le palier a 70 % qui separe la zone 2 de la zone 3
  chez Garmin tombe, chez un coureur entraine, nettement **sous** son premier
  seuil ventilatoire — donc une allure franchement facile se retrouve classee
  en zone 3.

  C'est exactement ce qui se produisait ici : le panneau de signaux annoncait
  un entrainement peu polarise en comparant « sous la zone 3 de Garmin » a la
  frontiere du modele polarise, qui est le premier seuil ventilatoire. Les
  deux ne sont pas au meme endroit.

  ## Ce que ce module mesure

  **La frequence maximale observee** : le maximum releve sur l'ensemble des
  seances. C'est une borne inferieure de la vraie maximale — on ne l'atteint
  pas a chaque sortie — mais elle est mesuree, pas supposee.

  **La frequence au seuil**, estimee sur les efforts soutenus a l'allure de
  vitesse critique. La vitesse critique est, par construction, l'allure
  soutenable en aerobie ; la frequence cardiaque qui l'accompagne sur quinze
  a trente minutes est une bonne approximation de terrain du seuil lactique.
  C'est la grandeur la plus solide dont on dispose, parce qu'elle croise deux
  mesures independantes — l'allure et le coeur.

  Les zones en decoulent par la methode des pourcentages du seuil, qui est
  celle employee en course a pied precisement parce qu'elle s'ancre sur une
  grandeur mesurable, contrairement a la frequence maximale.
  """

  import Ecto.Query

  alias Soleus.Analytics
  alias Soleus.Analytics.Vdot
  alias Soleus.Repo
  alias Soleus.Training
  alias Soleus.Training.{Activity, BestEffort}

  # Pourcentages du seuil delimitant les zones 1 a 5. Repartition usuelle en
  # course a pied : la zone 4 encadre le seuil, la zone 5 est au dela.
  @floors [0.80, 0.85, 0.90, 0.95, 1.00]

  # Frontiere entre « facile » et « modere » au sens du modele polarise. Le
  # premier seuil ventilatoire ne se mesure qu'avec analyse des gaz ; en
  # pratique on le situe autour de 90 % du seuil lactique, ce qui correspond
  # au palier zone 2 / zone 3 ci-dessus.
  #
  # Ce chiffre est une approximation de terrain, pas une mesure. Il merite
  # d'etre affiche comme tel, et la part de temps facile doit se lire comme
  # un ordre de grandeur.
  @easy_boundary 0.90

  @type t :: %{
          max_hr: integer() | nil,
          threshold_hr: integer() | nil,
          floors: [integer()],
          easy_below: integer() | nil,
          samples: non_neg_integer(),
          source: :measured | :unavailable
        }

  @doc """
  Derive les zones a partir des seances enregistrees.

  Rend `source: :unavailable` quand il n'y a pas assez d'efforts soutenus
  pour estimer le seuil : mieux vaut ne rien proposer qu'un decoupage bati
  sur deux sorties.
  """
  @spec derive(String.t()) :: t()
  def derive(sport \\ "run") do
    max_hr = observed_max_hr(sport)
    {threshold, samples} = threshold_hr(sport)

    if is_nil(threshold) do
      %{
        max_hr: max_hr,
        threshold_hr: nil,
        floors: [],
        easy_below: nil,
        samples: samples,
        source: :unavailable
      }
    else
      %{
        max_hr: max_hr,
        threshold_hr: threshold,
        floors: Enum.map(@floors, &round(threshold * &1)),
        easy_below: round(threshold * @easy_boundary),
        samples: samples,
        source: :measured
      }
    end
  end

  @doc "Frequence maximale relevee sur l'ensemble des seances."
  @spec observed_max_hr(String.t()) :: integer() | nil
  def observed_max_hr(sport \\ "run") do
    Repo.one(from a in Activity, where: a.sport == ^sport, select: max(a.max_hr))
  end

  @doc """
  Frequence au seuil, estimee sur les efforts **maximaux** de vingt a
  quarante minutes.

  C'est la transposition du test de terrain usuel : la frequence moyenne d'un
  contre-la-montre de trente minutes approche le seuil lactique. On retient
  donc, pour chaque palier de duree, l'effort **le plus rapide** de
  l'historique, et la mediane de leurs frequences.

  ## Pourquoi pas tous les efforts a l'allure de seuil

  C'etait la premiere approche, et elle donnait 166 au lieu de 186. La cause
  est l'inertie cardiaque : sur cet athlete, la frequence met souvent plus de
  dix minutes a monter, et une fenetre de quinze minutes prise en debut de
  sortie affiche 125 battements a une allure pourtant proche du seuil. Ces
  fenetres sont de vraies mesures, pas des artefacts — elles disent juste
  autre chose que ce qu'on cherchait.

  Les efforts maximaux echappent a ce biais : quand on court son meilleur
  trente minutes, la frequence a eu le temps de monter.

  Rend `{nil, n}` en dessous de trois efforts exploitables.
  """
  @spec threshold_hr(String.t()) :: {integer() | nil, non_neg_integer()}
  def threshold_hr(sport \\ "run") do
    heart_rates =
      from(e in BestEffort,
        join: a in Activity,
        on: a.id == e.activity_id,
        where: e.kind == "duration" and a.sport == ^sport,
        where: not is_nil(e.avg_hr),
        # Quinze a quarante-cinq minutes. La borne basse a 1 200 s ne laissait
        # que deux paliers dans la courbe — pas de quoi prendre une mediane.
        where: e.duration_s >= 900 and e.duration_s <= 2700,
        group_by: e.duration_s,
        # Pour chaque palier, la frequence de l'effort le plus rapide. Le
        # `max` sur la vitesse et le `max` sur la frequence portent sur le
        # meme groupe, et chez cet athlete les deux designent le meme effort :
        # le plus rapide est aussi celui ou la frequence a le plus monte.
        select: {e.duration_s, max(e.speed_ms), max(e.avg_hr)}
      )
      |> Repo.all()
      |> Enum.map(fn {_duration, _speed, hr} -> hr end)
      |> Enum.sort()

    case length(heart_rates) do
      n when n < 3 -> {nil, n}
      n -> {Enum.at(heart_rates, div(n, 2)), n}
    end
  end

  @doc """
  Recalcule le temps par zone depuis les series, avec les planchers fournis.

  Indispensable des lors qu'on quitte les zones de la montre : les durees
  pre-calculees par Garmin sont liees a **ses** paliers, et les reutiliser
  avec d'autres bornes donnerait des chiffres qui ne veulent rien dire.

  Le cout est reel — il faut relire chaque serie — d'ou la limite de periode.
  """
  @spec time_in_zones([integer()], Date.t(), Date.t(), String.t()) :: [non_neg_integer()]
  def time_in_zones(floors, from, to, sport \\ "run")

  def time_in_zones([], _from, _to, _sport), do: List.duplicate(0, 6)

  def time_in_zones(floors, from, to, sport) do
    from(a in Activity,
      where: a.sport == ^sport and a.local_date >= ^from and a.local_date <= ^to,
      select: a.id
    )
    |> Repo.all()
    |> Enum.reduce(List.duplicate(0, 6), fn id, acc ->
      case Training.load_series(id) do
        %{hr: hrs} when is_list(hrs) -> tally(hrs, floors, acc)
        _no_series -> acc
      end
    end)
  end

  # Les series sont echantillonnees a une seconde pres ; chaque point compte
  # donc pour une seconde. L'ecart avec la duree reelle reste sous le pour
  # cent, et l'alternative — ponderer par l'intervalle entre deux points —
  # n'ajouterait de la precision que la ou la donnee n'en a pas.
  defp tally(hrs, floors, acc) do
    Enum.reduce(hrs, acc, fn
      nil, counts -> counts
      hr, counts -> List.update_at(counts, zone_of(hr, floors), &(&1 + 1))
    end)
  end

  @doc """
  Indice de zone d'une frequence, de 0 — sous la premiere zone — a 5.

      iex> Soleus.Analytics.Zones.zone_of(150, [149, 158, 167, 177, 186])
      1
      iex> Soleus.Analytics.Zones.zone_of(100, [149, 158, 167, 177, 186])
      0
      iex> Soleus.Analytics.Zones.zone_of(200, [149, 158, 167, 177, 186])
      5
  """
  @spec zone_of(number(), [integer()]) :: 0..5
  def zone_of(hr, floors) do
    Enum.count(floors, &(hr >= &1))
  end

  @doc """
  Part du temps passee sous la frontiere du facile, en pourcentage.

  C'est le chiffre que le modele polarise situe autour de 80 %. Rend `nil`
  sans donnee plutot que zero, qui se lirait comme « rien de facile ».
  """
  @spec easy_share([non_neg_integer()], integer() | nil, [integer()]) :: float() | nil
  def easy_share(zone_seconds, easy_below, floors) do
    total = Enum.sum(zone_seconds)

    with true <- total > 0,
         index when is_integer(index) <- easy_index(easy_below, floors) do
      zone_seconds |> Enum.take(index) |> Enum.sum() |> Kernel./(total) |> Kernel.*(100)
    else
      _no_data -> nil
    end
  end

  defp easy_index(nil, _floors), do: nil
  defp easy_index(easy_below, floors), do: Enum.count(floors, &(&1 <= easy_below))

  @doc """
  Repartition du temps de course par **allure**, et non par frequence.

  C'est la mesure a privilegier chez un athlete dont la frequence met du
  temps a monter : l'allure, elle, est immediate. Sur l'historique present,
  les deux lectures donnent 72 % et 34 % de temps facile — l'ecart ne vient
  pas d'un desaccord sur l'entrainement, mais de ce que la frequence
  cardiaque mesure autre chose que l'effort fourni pendant les dix premieres
  minutes.

  Les quatre bandes sont ancrees sur des allures derivees de l'athlete :
  allure marathon et allure seuil issues du VDOT, vitesse critique issue de
  la courbe des meilleurs efforts.

  Rend `[facile, modere, seuil, dur]` en secondes.
  """
  @spec pace_distribution(Date.t(), Date.t(), String.t()) :: [non_neg_integer()]
  def pace_distribution(from, to, sport \\ "run") do
    fit = Analytics.current_fit(sport)

    with %{cs_ms: cs, vdot: vdot} when is_number(cs) and is_number(vdot) <- fit,
         paces = Vdot.training_speeds(vdot),
         true <- is_number(paces[:marathon]) and is_number(paces[:threshold]) do
      bounds = {paces[:marathon], paces[:threshold], cs * 1.03}

      from(a in Activity,
        where: a.sport == ^sport and a.local_date >= ^from and a.local_date <= ^to,
        select: a.id
      )
      |> Repo.all()
      |> Enum.reduce([0, 0, 0, 0], &accumulate_pace(&1, &2, bounds))
    else
      _no_model -> [0, 0, 0, 0]
    end
  end

  defp accumulate_pace(id, acc, bounds) do
    case Training.load_series(id) do
      %{speed_ms: speeds} when is_list(speeds) -> tally_pace(speeds, bounds, acc)
      _no_series -> acc
    end
  end

  # Les points a l'arret sont ecartes : une pause au feu rouge compterait
  # sinon comme du temps facile, et gonflerait la part la plus flatteuse.
  @min_speed_ms 1.5

  defp tally_pace(speeds, {marathon, threshold, hard}, acc) do
    Enum.reduce(speeds, acc, fn
      nil, counts ->
        counts

      speed, counts when speed < @min_speed_ms ->
        counts

      speed, counts ->
        index =
          cond do
            speed < marathon -> 0
            speed < threshold -> 1
            speed < hard -> 2
            true -> 3
          end

        List.update_at(counts, index, &(&1 + 1))
    end)
  end

  @doc """
  Part du temps facile selon l'allure, en pourcentage.

  « Facile » est la **premiere bande seulement** : plus lent que l'allure
  marathon. La bande suivante, de l'allure marathon a l'allure seuil, est la
  zone grise du modele polarise — ni assez facile pour recuperer, ni assez
  dure pour developper. L'y inclure gonflerait le chiffre de dix points et
  flatterait la lecture.
  """
  @spec easy_pace_share([non_neg_integer()]) :: float() | nil
  def easy_pace_share(bands) do
    total = Enum.sum(bands)
    if total > 0, do: bands |> List.first() |> Kernel./(total) |> Kernel.*(100)
  end

  @doc "Part du temps en zone grise — entre allure marathon et allure seuil."
  @spec grey_pace_share([non_neg_integer()]) :: float() | nil
  def grey_pace_share(bands) do
    total = Enum.sum(bands)
    if total > 0, do: bands |> Enum.at(1) |> Kernel./(total) |> Kernel.*(100)
  end

  @doc "Libelles des quatre bandes d'allure."
  def pace_bands, do: ["facile", "zone grise", "seuil", "dur"]

  @doc """
  Inertie cardiaque : le temps que met la frequence a rejoindre le regime de
  la seance.

  Mesure, pour chaque sortie de plus de trente minutes, le delai avant
  d'atteindre 90 % de la frequence mediane de cette seance, puis rend les
  quartiles.

  La grandeur n'a rien d'academique, mais elle explique pourquoi les zones de
  frequence decrivent mal le debut d'une sortie chez certains athletes. Une
  mediane autour de trois a cinq minutes est banale ; un troisieme quartile
  au dela de dix minutes signifie qu'un quart des seances passent leur
  premier quart d'heure a une frequence qui ne reflete pas l'allure.
  """
  @spec cardiac_lag(String.t()) ::
          %{median_s: integer(), p75_s: integer(), samples: integer()} | nil
  def cardiac_lag(sport \\ "run") do
    delays =
      from(a in Activity,
        where: a.sport == ^sport and a.moving_time_s > 1800,
        select: a.id
      )
      |> Repo.all()
      |> Enum.flat_map(&lag_of/1)
      |> Enum.sort()

    case length(delays) do
      n when n < 10 ->
        nil

      n ->
        %{
          median_s: Enum.at(delays, div(n, 2)),
          p75_s: Enum.at(delays, div(3 * n, 4)),
          samples: n
        }
    end
  end

  defp lag_of(id) do
    case Training.load_series(id) do
      %{hr: hrs, t: times} when is_list(hrs) ->
        pairs = times |> Enum.zip(hrs) |> Enum.reject(fn {t, hr} -> is_nil(t) or is_nil(hr) end)

        if length(pairs) > 300, do: first_crossing(pairs), else: []

      _no_series ->
        []
    end
  end

  # La cible est la mediane de la seance et non un pourcentage de la
  # frequence maximale : un footing et un fractionne n'ont pas le meme
  # regime, et comparer chacun au sien evite de confondre inertie et
  # intensite.
  defp first_crossing(pairs) do
    values = pairs |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    target = Enum.at(values, div(length(values), 2)) * 0.9

    case Enum.find(pairs, fn {_t, hr} -> hr >= target end) do
      {t, _hr} -> [t]
      nil -> []
    end
  end

  @doc "Les pourcentages de seuil utilises, pour les afficher."
  def floor_fractions, do: @floors

  @doc "La fraction du seuil retenue comme frontiere du facile."
  def easy_fraction, do: @easy_boundary
end
