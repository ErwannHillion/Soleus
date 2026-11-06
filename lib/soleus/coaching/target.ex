defmodule Soleus.Coaching.Target do
  @moduledoc """
  L'objectif d'une course : distance, denivele, date, et temps vise.

  ## La saisie du temps

  On ecrit un objectif comme on en parle. `sub 50`, `50:00`, `1h45`,
  `3:30:00` designent tous une chose claire pour un coureur, et exiger un
  format unique reviendrait a faire traduire a l'athlete ce qu'il a deja en
  tete.

  Le temps est **facultatif**. Sans lui, l'objectif est deduit de la forme
  actuelle et du temps disponible — c'est d'ailleurs le cas le plus utile :
  « qu'est-ce que je peux viser en douze semaines ? » est une meilleure
  question que « est-ce que je peux faire ce chiffre que j'ai sorti de nulle
  part ? ».
  """

  @doc """
  Interprete un temps cible ecrit librement.

  Rend des secondes, ou `:none` pour une saisie vide, ou `:error`.

      iex> Soleus.Coaching.Target.parse("sub 50")
      {:ok, 3000}
      iex> Soleus.Coaching.Target.parse("1h45")
      {:ok, 6300}
      iex> Soleus.Coaching.Target.parse("22:49")
      {:ok, 1369}
      iex> Soleus.Coaching.Target.parse("")
      :none
  """
  @spec parse(String.t() | nil) :: {:ok, pos_integer()} | :none | :error
  def parse(nil), do: :none

  def parse(raw) do
    cleaned =
      raw
      |> String.downcase()
      |> String.replace(~r/\s+/, "")
      |> String.replace(~r/^(sub|sous|moins de|<)/, "")

    if cleaned == "", do: :none, else: interpret(cleaned)
  end

  defp interpret(text) do
    cond do
      # 3:30:00 — heures, minutes, secondes
      match = Regex.run(~r/^(\d+):(\d{1,2}):(\d{1,2})$/, text) ->
        [_, h, m, s] = match
        seconds(to_i(h) * 3600 + to_i(m) * 60 + to_i(s))

      # 1h45 ou 1h45m30
      match = Regex.run(~r/^(\d+)h(\d{1,2})?(?:m?(\d{1,2})s?)?$/, text) ->
        [_, h | rest] = match
        [m, s] = Enum.map(0..1, &(Enum.at(rest, &1) || "0"))
        seconds(to_i(h) * 3600 + to_i(m) * 60 + to_i(s))

      # 50:00 — minutes et secondes
      match = Regex.run(~r/^(\d+):(\d{1,2})$/, text) ->
        [_, m, s] = match
        seconds(to_i(m) * 60 + to_i(s))

      # 50 ou 50min — des minutes rondes
      match = Regex.run(~r/^(\d+)(?:min|m)?$/, text) ->
        [_, m] = match
        seconds(to_i(m) * 60)

      true ->
        :error
    end
  end

  defp seconds(total) when total > 0, do: {:ok, total}
  defp seconds(_total), do: :error

  defp to_i(""), do: 0
  defp to_i(text), do: String.to_integer(text)

  # Classique en course nature : cent metres de denivele positif coutent a peu
  # pres autant qu'un kilometre de plat. La regle est grossiere — elle ignore
  # la pente moyenne, le profil et le gain de la descente — mais elle a le
  # merite d'etre celle que les coureurs utilisent, donc d'etre comprehensible
  # sans explication.
  @meters_per_climbed_meter 10

  @doc """
  Distance equivalente sur le plat, denivele compris.

      iex> Soleus.Coaching.Target.effective_distance(10_000, 150)
      11_500.0
  """
  @spec effective_distance(number(), number() | nil) :: float()
  def effective_distance(distance_m, nil), do: distance_m * 1.0

  def effective_distance(distance_m, elevation_m),
    do: distance_m + elevation_m * @meters_per_climbed_meter * 1.0

  @doc "Le facteur d'equivalence, pour l'afficher."
  def climb_factor, do: @meters_per_climbed_meter
end
