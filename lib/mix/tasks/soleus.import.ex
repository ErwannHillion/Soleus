defmodule Mix.Tasks.Soleus.Import do
  @shortdoc "Importe tous les fichiers FIT d'un dossier"

  @moduledoc """
  Importe en masse les fichiers FIT d'un export Garmin.

      mix soleus.import                    # priv/import/fit par defaut
      mix soleus.import /chemin/vers/fit

  L'operation est idempotente : l'empreinte du fichier sert de cle, donc
  relancer la tache sur le meme dossier ne cree aucun doublon. C'est voulu —
  on repasse sur un export apres l'avoir complete, et ca ne doit pas etre un
  geste risque.

  ## Ce que contient reellement un export Garmin

  Le dossier ne contient pas que des seances. Sur un export reel de 8 675
  fichiers, 134 sont des activites : tout le reste est du suivi quotidien, de
  la variabilite cardiaque nocturne et des sauvegardes de reglages. Ces
  fichiers sont ecartes silencieusement, pas comptes comme des echecs.

  ## Apres l'import

  La tache ne calcule aucune metrique. Enchainer avec :

      mix soleus.rebuild
  """

  use Mix.Task

  require Logger

  alias Soleus.Config
  alias Soleus.Training

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    Logger.configure(level: :warning)

    dir = List.first(args) || Path.join(Config.fit_import_dir(), "fit")
    files = Path.wildcard(Path.join(dir, "**/*.fit"))

    if files == [] do
      Mix.raise("Aucun fichier .fit dans #{dir}")
    end

    Mix.shell().info("#{length(files)} fichiers dans #{dir}\n")

    started = System.monotonic_time(:millisecond)
    tally = import_all(files)
    elapsed = (System.monotonic_time(:millisecond) - started) / 1000

    report(tally, elapsed)
  end

  defp import_all(files) do
    total = length(files)

    files
    |> Enum.with_index(1)
    |> Enum.reduce(%{imported: 0, skipped: 0, ignored: 0, failed: []}, fn {path, index}, tally ->
      progress(index, total)
      classify(path, tally)
    end)
  end

  defp classify(path, tally) do
    case Training.import_fit(path) do
      {:ok, :imported, _activity} ->
        Map.update!(tally, :imported, &(&1 + 1))

      {:ok, :already_imported, _activity} ->
        Map.update!(tally, :skipped, &(&1 + 1))

      # Suivi quotidien, HRV nocturne, sauvegarde de reglages : la grande
      # majorite du dossier. Ce n'est pas un echec.
      {:error, :not_an_activity} ->
        Map.update!(tally, :ignored, &(&1 + 1))

      {:error, :no_timestamp} ->
        Map.update!(tally, :ignored, &(&1 + 1))

      {:error, reason} ->
        Map.update!(tally, :failed, &[{Path.basename(path), reason} | &1])
    end
  end

  # Une ligne reecrite plutot qu'un defilement : la tache traite des milliers
  # de fichiers, et autant de lignes noieraient le rapport final.
  defp progress(index, total) when rem(index, 100) == 0 or index == total do
    IO.write("\r  #{index} / #{total}")
    if index == total, do: IO.write("\n")
  end

  defp progress(_index, _total), do: :ok

  defp report(tally, elapsed) do
    Mix.shell().info("""

    importees        #{tally.imported}
    deja presentes   #{tally.skipped}
    ignorees         #{tally.ignored}  (suivi quotidien, HRV, reglages)
    echecs           #{length(tally.failed)}
    duree            #{Float.round(elapsed, 1)} s\
    """)

    tally.failed
    |> Enum.take(10)
    |> Enum.each(fn {file, reason} ->
      Mix.shell().info("  #{file} : #{inspect(reason)}")
    end)

    if tally.imported > 0 do
      Mix.shell().info("\nEnchainer avec : mix soleus.rebuild")
    end
  end
end
