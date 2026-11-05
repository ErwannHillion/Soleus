defmodule Mix.Tasks.Soleus.Rebuild do
  @shortdoc "Recalcule metriques, charge et modeles sur tout l'historique"

  @moduledoc """
  Reconstruit tout ce qui est derive, dans l'ordre de dependance.

      mix soleus.rebuild

  A lancer apres un import de masse, ou apres avoir change une formule du
  moteur. Les quatre etapes suivent la chaine de dependance, et aucune ne peut
  etre sautee :

    1. metriques par seance ;
    2. serie de charge quotidienne (Banister) ;
    3. **ajustements historiques** des modeles, un par jour ;
    4. ajustement du jour.

  L'etape 3 est celle qu'on oublie. Sans elle il n'existe qu'un seul
  ajustement, celui d'aujourd'hui, et la projection de progression n'a aucune
  pente a extrapoler : elle a besoin de la serie des vitesses critiques
  passees, pas seulement de la valeur actuelle.
  """

  use Mix.Task

  require Logger

  alias Soleus.{Analytics, Training}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_args) do
    # La tache ecrit des milliers de lignes ; sa sortie doit etre son rapport et
    # non le journal SQL de la configuration de developpement.
    Logger.configure(level: :warning)

    Mix.shell().info("1/4  Metriques par seance...")
    {:ok, analyzed} = Analytics.analyze_pending()
    Mix.shell().info("     #{analyzed} seances analysees")

    Mix.shell().info("2/4  Charge quotidienne...")
    {:ok, days} = Analytics.rebuild_daily_loads()
    Mix.shell().info("     #{inspect(days)} jours")

    Mix.shell().info("3/4  Ajustements historiques...")
    fits = backfill_fits()
    Mix.shell().info("     #{fits} ajustements")

    Mix.shell().info("4/4  Ajustement du jour...")
    {:ok, _} = Analytics.fit_models()

    report()
  end

  # Un ajustement par jour, a partir du moment ou la fenetre glissante est
  # pleine. Avant cela l'ajustement porterait sur une periode incomplete et
  # produirait une vitesse critique artificiellement basse, qui ressemblerait
  # a une progression alors que ce n'est qu'un effet de bord du demarrage.
  defp backfill_fits do
    case Training.first_activity_date() do
      nil -> 0
      first -> fit_each_day(Date.add(first, Analytics.fit_window_days()), Date.utc_today())
    end
  end

  # `Date.compare/2` et non l'operateur `>` : comparer deux `%Date{}` avec `>`
  # suit l'ordre des termes Erlang, qui classe les cles du struct par ordre
  # alphabetique. Le jour est donc compare avant l'annee, et le 1er janvier 2027
  # passerait pour anterieur au 2 decembre 2026.
  defp fit_each_day(from, today) do
    if Date.compare(from, today) == :gt do
      0
    else
      from
      |> Date.range(today)
      |> Enum.count(&match?({:ok, _fit}, Analytics.fit_models("run", &1)))
    end
  end

  defp report do
    alias Soleus.Analytics.Pace

    case Analytics.current_fit() do
      nil ->
        Mix.shell().info("\nAucun modele ajuste.")

      fit ->
        Mix.shell().info("\n--- modele du #{fit.fitted_on} ---")

        Mix.shell().info(
          "vitesse critique  #{fmt(fit.cs_ms)} m/s  (#{Pace.format(fit.cs_ms)} /km)"
        )

        Mix.shell().info("reserve D'        #{fmt(fit.d_prime_m)} m")
        Mix.shell().info("R2                #{fmt(fit.r2)}")
        Mix.shell().info("VDOT              #{fmt(fit.vdot)}")

        Mix.shell().info("\npredictions :")

        fit.predictions
        |> Enum.sort_by(fn {d, _} -> String.to_integer(d) end)
        |> Enum.each(fn {distance, time} ->
          label = distance |> String.to_integer() |> Pace.distance_label()
          Mix.shell().info("  #{String.pad_trailing(label, 10)} #{Pace.format_duration(time)}")
        end)
    end
  end

  defp fmt(nil), do: "—"
  defp fmt(n) when is_float(n), do: Float.round(n, 3) |> to_string()
  defp fmt(n), do: to_string(n)
end
