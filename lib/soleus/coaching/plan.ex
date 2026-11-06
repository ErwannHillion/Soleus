defmodule Soleus.Coaching.Plan do
  @moduledoc """
  Construit un plan d'entrainement vers une course datee.

  ## Ce que ce module est, et ce qu'il n'est pas

  Ce n'est pas un entraineur. C'est une **mise en forme de contraintes
  mesurees** : la charge actuelle de l'athlete, son rythme de seances reel,
  ses allures derivees de sa vitesse critique, et un taux de montee en charge
  que la litterature sur la blessure situe autour de cinq points de charge
  chronique par semaine.

  Tout ce que le plan propose decoule de ces quatre chiffres. Il ne sait rien
  de la vie de l'athlete, de son sommeil a venir, de ses contraintes
  professionnelles ni de son historique de blessures. Il doit donc etre lu
  comme une trame a adapter, et l'interface le dit.

  ## Les quatre partis pris

  **Le nombre de seances vient de l'historique, pas d'un ideal.** Proposer six
  seances par semaine a quelqu'un qui en fait deux produit un plan que
  personne ne suit, et dont l'echec se lit comme un echec de l'athlete.

  **La charge monte par paliers, avec des semaines de relache.** Une semaine
  allegee toutes les quatre semaines : c'est pendant la baisse de charge que
  l'adaptation se realise, pas pendant la montee.

  **La duree de chaque seance est calculee, pas choisie.** Chaque type a son
  facteur d'intensite ; la duree se deduit de la part de charge
  hebdomadaire qui lui revient. Le plan et le moteur de charge parlent donc le
  meme langage, et la charge prevue est comparable a la charge reelle.

  **L'affutage reduit le volume, pas l'intensite.** C'est le consensus, et
  l'inverse — se reposer en douceur — laisse arriver emousse.
  """

  alias Soleus.Analytics
  alias Soleus.Analytics.{Pace, Vdot}

  # Montee de charge, par semaine. Deux bornes, et c'est la plus basse qui
  # s'applique :
  #
  #   * **dix pour cent** de la charge en cours. C'est la regle usuelle, et la
  #     seule qui ait du sens a bas volume : passer de 88 a 116 points serait
  #     un bond de trente pour cent, meme si l'ecart absolu parait modeste ;
  #   * **quatre points de charge chronique**, soit vingt-huit points
  #     hebdomadaires — le plafond pour un athlete deja charge.
  #
  # Une seule des deux suffirait a produire des plans dangereux : la regle des
  # dix pour cent devient explosive a haut volume, le plafond absolu l'est a
  # bas volume.
  @relative_ramp 0.10
  @max_weekly_ramp 4.0

  # Plafond sur l'ensemble du cycle : la charge hebdomadaire ne depasse pas le
  # double de celle du depart. Composer dix pour cent par semaine pendant dix
  # semaines multiplie la charge par 2,6, ce qui est le mode d'echec connu de
  # cette regle — elle est pensee pour une progression ponctuelle, pas pour
  # etre appliquee en continu sur un cycle entier.
  @cycle_ceiling 2.0

  # Une semaine allegee toutes les quatre : la charge se transforme en forme
  # pendant la baisse, pas pendant la montee.
  @recovery_week_every 4
  @recovery_factor 0.72

  # Affutage : deux semaines quand le temps le permet, une seule sinon.
  @taper_factors [0.70, 0.50]

  @type session :: %{
          kind: atom(),
          label: String.t(),
          duration_s: integer(),
          pace_ms: float() | nil,
          structure: String.t(),
          load: float()
        }

  @doc """
  Construit le plan.

  `weeks` est le nombre de semaines pleines jusqu'a la course.
  """
  @spec build(map()) :: map()
  def build(%{weeks: weeks} = params) when weeks >= 1 do
    fit = Analytics.current_fit(params[:sport] || "run")
    paces = paces(fit)
    frequency = session_frequency()
    start_load = weekly_load_now()

    blocks = phases(weeks)
    targets = weekly_targets(start_load, blocks, params)

    %{
      weeks:
        Enum.zip(blocks, targets)
        |> Enum.with_index(1)
        |> Enum.map(&week(&1, params, paces, frequency)),
      frequency: frequency,
      paces: paces,
      start_weekly_load: start_load,
      peak_weekly_load: targets |> Enum.max(fn -> 0.0 end),
      ramp: @max_weekly_ramp
    }
  end

  def build(_params),
    do: %{
      weeks: [],
      frequency: 0,
      paces: %{},
      start_weekly_load: 0.0,
      peak_weekly_load: 0.0,
      ramp: @max_weekly_ramp
    }

  # -- phases -----------------------------------------------------------------

  # En dessous de huit semaines, le bloc de base disparait. Une preparation
  # courte n'a pas le temps de construire un socle puis de l'exploiter : lui
  # consacrer une semaine ou deux revient a amputer le developpement, qui est
  # la seule partie qui fera la difference le jour J.
  @min_weeks_for_base 8

  defp phases(weeks) do
    taper = min(length(@taper_factors), max(div(weeks, 6), 1))
    remaining = weeks - taper

    peak = min(remaining, max(div(remaining, 3), 1))
    rest = remaining - peak
    base = if weeks >= @min_weeks_for_base, do: max(rest - div(remaining, 2), 0), else: 0

    List.duplicate(:base, base) ++
      List.duplicate(:build, rest - base) ++
      List.duplicate(:peak, peak) ++
      List.duplicate(:taper, taper)
  end

  # -- charge hebdomadaire ----------------------------------------------------

  # La charge part de celle que l'athlete porte deja et monte au rythme
  # autorise, sauf les semaines de relache et l'affutage. Demarrer plus haut
  # que l'existant serait le moyen le plus sur de se blesser en semaine deux.
  defp weekly_targets(start_load, blocks, _params) do
    ceiling = start_load * @cycle_ceiling
    taper_count = Enum.count(blocks, &(&1 == :taper))
    build_count = length(blocks) - taper_count

    {targets, _} =
      blocks
      |> Enum.with_index()
      |> Enum.map_reduce(start_load, fn {phase, index}, load ->
        step(phase, index, load, %{
          start_load: start_load,
          ceiling: ceiling,
          build_count: build_count
        })
      end)

    targets
  end

  defp step(:taper, index, load, %{start_load: start, build_count: built}) do
    factor = Enum.at(@taper_factors, index - built, List.last(@taper_factors))
    {peak_of(start, built) * factor, load}
  end

  # La semaine de relache allege la charge affichee mais ne remet pas la
  # progression a zero : la semaine suivante repart du niveau atteint, pas du
  # niveau allege.
  defp step(_phase, index, load, %{ceiling: ceiling}) do
    next = load + ramp_step(load, ceiling)

    if rem(index + 1, @recovery_week_every) == 0 do
      {load * @recovery_factor, next}
    else
      {next, next}
    end
  end

  defp ramp_step(load, ceiling) do
    min(load * @relative_ramp, @max_weekly_ramp * 7) |> min(max(ceiling - load, 0.0))
  end

  # Le pic sert de reference a l'affutage. Il se calcule en deroulant la meme
  # montee que `weekly_targets/3` plutot que par une formule approchee : les
  # deux doivent coincider, sinon l'affutage partirait d'un niveau que
  # l'athlete n'a jamais atteint.
  defp peak_of(start_load, build_count) do
    ceiling = start_load * @cycle_ceiling

    Enum.reduce(1..max(build_count, 1)//1, start_load, fn _week, load ->
      load + ramp_step(load, ceiling)
    end)
  end

  # Charge hebdomadaire actuelle, deduite de la charge chronique : a l'etat
  # stationnaire, la charge chronique est la moyenne quotidienne, donc sept
  # fois celle-ci est le volume hebdomadaire equivalent.
  defp weekly_load_now do
    case Analytics.current_form() do
      %{ctl: ctl} when is_number(ctl) and ctl > 0 -> ctl * 7
      _none -> 150.0
    end
  end

  # Rythme reel des huit dernieres semaines, arrondi. Plancher a trois : en
  # dessous, aucune progression n'est possible et le plan n'aurait pas de
  # sens ; plafond a six, au dela c'est un autre metier.
  defp session_frequency do
    today = Date.utc_today()
    days = Analytics.load_series(56)
    sessions = days |> Enum.map(&(&1.activity_count || 0)) |> Enum.sum()
    weeks = max(length(days) / 7, 1)

    _ = today
    (sessions / weeks) |> round() |> max(3) |> min(6)
  end

  # -- une semaine ------------------------------------------------------------

  defp week({{phase, target_load}, index}, params, paces, frequency) do
    sessions = sessions_for(phase, frequency, target_load, paces, params)

    %{
      index: index,
      phase: phase,
      label: phase_label(phase),
      target_load: target_load,
      sessions: sessions,
      total_duration_s: sessions |> Enum.map(& &1.duration_s) |> Enum.sum()
    }
  end

  # Repartition de la charge entre les seances, par phase. Les poids sont des
  # parts, normalisees ensuite : c'est le seul endroit ou la forme du plan se
  # decide, et le rendre lisible compte plus que de le rendre compact.
  defp template(:base),
    do: [
      {:long, 0.40},
      {:easy, 0.25},
      {:easy, 0.20},
      {:threshold, 0.15},
      {:easy, 0.10},
      {:easy, 0.10}
    ]

  defp template(:build),
    do: [
      {:long, 0.33},
      {:threshold, 0.22},
      {:easy, 0.17},
      {:intervals, 0.16},
      {:easy, 0.12},
      {:easy, 0.10}
    ]

  defp template(:peak),
    do: [
      {:long, 0.28},
      {:intervals, 0.22},
      {:race_pace, 0.20},
      {:easy, 0.14},
      {:threshold, 0.12},
      {:easy, 0.10}
    ]

  defp template(:taper),
    do: [
      {:race_pace, 0.30},
      {:easy, 0.25},
      {:intervals, 0.20},
      {:easy, 0.15},
      {:easy, 0.10},
      {:easy, 0.10}
    ]

  defp sessions_for(phase, frequency, target_load, paces, params) do
    chosen = phase |> template() |> Enum.take(frequency)
    total_weight = chosen |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    chosen
    |> Enum.map(fn {kind, weight} ->
      session(kind, target_load * weight / total_weight, paces, params, phase)
    end)
    |> Enum.reject(&(&1.duration_s < 600))
  end

  # -- une seance -------------------------------------------------------------

  # Facteur d'intensite moyen de la seance entiere, echauffement et
  # recuperations compris. C'est lui qui relie la charge visee a une duree,
  # par la meme formule que le moteur d'analyse : charge = t/3600 x IF^2 x 100.
  defp intensity(:easy), do: 0.72
  defp intensity(:long), do: 0.76
  defp intensity(:threshold), do: 0.88
  defp intensity(:intervals), do: 0.92
  defp intensity(:race_pace), do: 0.90

  defp session(kind, load, paces, params, phase) do
    factor = intensity(kind)
    duration = load * 3600 / (factor * factor * 100)

    %{
      kind: kind,
      label: label(kind),
      duration_s: round(duration),
      pace_ms: pace_for(kind, paces, params),
      structure: structure(kind, round(duration), paces, params, phase),
      load: Float.round(load, 1)
    }
  end

  defp pace_for(:easy, paces, _params), do: paces[:easy]
  defp pace_for(:long, paces, _params), do: paces[:easy]
  defp pace_for(:threshold, paces, _params), do: paces[:threshold]
  defp pace_for(:intervals, paces, _params), do: paces[:interval]
  defp pace_for(:race_pace, _paces, params), do: params[:race_pace_ms]

  defp label(:easy), do: "Footing"
  defp label(:long), do: "Sortie longue"
  defp label(:threshold), do: "Seuil"
  defp label(:intervals), do: "Fractionne"
  defp label(:race_pace), do: "Allure course"

  # L'echauffement et le retour au calme sont proportionnes et bornes, et le
  # travail prend ce qui reste. Les figer a vingt minutes produisait des
  # seances dont les morceaux ne faisaient pas la duree annoncee : sur une
  # sortie de vingt-huit minutes, il ne restait qu'une minute de retour au
  # calme apres un echauffement plus long que le travail lui-meme.
  defp warmup(duration), do: duration |> Kernel.*(0.25) |> min(900) |> max(360) |> round()
  defp cooldown(duration), do: duration |> Kernel.*(0.15) |> min(600) |> max(300) |> round()

  # La structure est decrite en clair plutot que modelisee : l'athlete la lit,
  # il ne la calcule pas. Les durees de blocs suivent l'usage — des series de
  # cinq a quinze minutes au seuil, de trois a cinq minutes en fractionne.
  defp structure(:easy, duration, paces, _params, _phase) do
    "#{minutes(duration)} en aisance respiratoire a #{pace(paces[:easy])}"
  end

  defp structure(:long, duration, paces, _params, phase) do
    tail =
      if phase in [:build, :peak],
        do: ", dont les 20 dernieres minutes a #{pace(paces[:marathon])}",
        else: ""

    "#{minutes(duration)} a #{pace(paces[:easy])}#{tail}"
  end

  defp structure(:threshold, duration, paces, _params, _phase) do
    up = warmup(duration)
    down = cooldown(duration)
    work = max(duration - up - down, 360)
    blocks = work |> div(600) |> max(2) |> min(5)
    each = div(work - (blocks - 1) * 120, blocks)

    "#{minutes(up)} echauffement · #{blocks} x #{minutes(each)} a #{pace(paces[:threshold])} " <>
      "(2 min trot entre les blocs) · #{minutes(down)} retour au calme"
  end

  defp structure(:intervals, duration, paces, _params, _phase) do
    up = warmup(duration)
    down = cooldown(duration)
    # Le bloc central contient le travail **et** les recuperations, de meme
    # duree : seule la moitie est courue vite.
    middle = max(duration - up - down, 480)
    reps = middle |> div(360) |> max(4) |> min(10)
    each = div(middle, reps * 2)

    "#{minutes(up)} echauffement · #{reps} x #{minutes(each)} a #{pace(paces[:interval])} " <>
      "(recuperation de meme duree en trot) · #{minutes(down)} retour au calme"
  end

  defp structure(:race_pace, duration, paces, params, _phase) do
    up = warmup(duration)
    down = cooldown(duration)
    work = max(duration - up - down, 360)
    target = params[:race_pace_ms] || paces[:marathon]

    "#{minutes(up)} echauffement · #{minutes(work)} a #{pace(target)} · " <>
      "#{minutes(down)} retour au calme"
  end

  defp phase_label(:base), do: "Base"
  defp phase_label(:build), do: "Developpement"
  defp phase_label(:peak), do: "Specifique"
  defp phase_label(:taper), do: "Affutage"

  defp minutes(seconds), do: "#{max(round(seconds / 60), 1)} min"
  defp pace(nil), do: "allure libre"
  defp pace(speed), do: "#{Pace.format(speed)}/km"

  defp paces(nil), do: %{}
  defp paces(%{vdot: vdot}) when is_number(vdot), do: Vdot.training_speeds(vdot)
  defp paces(_fit), do: %{}

  @doc "Les libelles de phase, pour la legende."
  def phase_labels,
    do: [base: "Base", build: "Developpement", peak: "Specifique", taper: "Affutage"]
end
