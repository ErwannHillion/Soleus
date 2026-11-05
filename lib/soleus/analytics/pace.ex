defmodule Soleus.Analytics.Pace do
  @moduledoc "Conversions et mise en forme des allures, vitesses et durees."

  @doc """
  Allure en secondes par kilometre depuis une vitesse en m/s.

      iex> Soleus.Analytics.Pace.per_km(3.0) |> Float.round(1)
      333.3
  """
  @spec per_km(number() | nil) :: float() | nil
  def per_km(nil), do: nil
  def per_km(speed_ms) when speed_ms > 0, do: 1000.0 / speed_ms
  def per_km(_), do: nil

  @doc "Vitesse en m/s depuis une allure en secondes par kilometre."
  @spec from_per_km(number() | nil) :: float() | nil
  def from_per_km(nil), do: nil
  def from_per_km(s_per_km) when s_per_km > 0, do: 1000.0 / s_per_km
  def from_per_km(_), do: nil

  @doc """
  Allure formatee comme sur une montre.

      iex> Soleus.Analytics.Pace.format(3.0)
      "5:33"
  """
  @spec format(number() | nil) :: String.t()
  def format(nil), do: "—"

  def format(speed_ms) when speed_ms > 0 do
    speed_ms |> per_km() |> format_duration()
  end

  def format(_), do: "—"

  @doc """
  Duree lisible : `m:ss` en dessous de l'heure, `h:mm:ss` au dela.

      iex> Soleus.Analytics.Pace.format_duration(1369)
      "22:49"
      iex> Soleus.Analytics.Pace.format_duration(9045)
      "2:30:45"
  """
  @spec format_duration(number() | nil) :: String.t()
  def format_duration(nil), do: "—"

  def format_duration(seconds) when is_number(seconds) and seconds >= 0 do
    total = round(seconds)
    h = div(total, 3600)
    m = total |> rem(3600) |> div(60)
    s = rem(total, 60)

    if h > 0 do
      "#{h}:#{pad(m)}:#{pad(s)}"
    else
      "#{m}:#{pad(s)}"
    end
  end

  def format_duration(_), do: "—"

  @doc """
  Nom court d'une distance de course, quand elle en a un.

      iex> Soleus.Analytics.Pace.distance_label(21_097.5)
      "Semi"
      iex> Soleus.Analytics.Pace.distance_label(3000.0)
      "3 km"
  """
  @spec distance_label(number()) :: String.t()
  def distance_label(m) do
    case round(m) do
      1609 -> "Mile"
      21_097 -> "Semi"
      21_098 -> "Semi"
      42_195 -> "Marathon"
      n when n < 1000 -> "#{n} m"
      n when rem(n, 1000) == 0 -> "#{div(n, 1000)} km"
      n -> "#{Float.round(n / 1000, 1)} km"
    end
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
