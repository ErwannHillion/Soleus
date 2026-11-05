defmodule Soleus.Analytics.Regression do
  @moduledoc """
  Moindres carres ordinaires sur un nuage de points.

  Ecrit en Elixir pur et non via une bibliotheque de calcul : les ajustements
  de Soleus portent sur quelques dizaines de points, jamais sur des matrices.
  A cette taille la forme fermee est exacte, instantanee, et evite une
  dependance native de plus a faire compiler.
  """

  @type point :: {number(), number()}
  @type t :: %{
          slope: float(),
          intercept: float(),
          r2: float(),
          n: pos_integer(),
          residual_sd: float() | nil
        }

  @doc """
  Ajuste `y = slope * x + intercept`.

  Rend `:error` plutot qu'un resultat douteux quand il y a moins de trois
  points ou quand tous les `x` sont identiques : dans ces deux cas la pente
  n'est pas determinee, et une valeur retournee quand meme se propagerait en
  silence jusqu'a une prediction affichee a l'ecran.

      iex> {:ok, reg} = Soleus.Analytics.Regression.ols([{1, 3}, {2, 5}, {3, 7}])
      iex> {reg.slope, reg.intercept, reg.r2}
      {2.0, 1.0, 1.0}
  """
  @spec ols([point()]) :: {:ok, t()} | :error
  def ols(points) when is_list(points) do
    n = length(points)

    if n < 3 do
      :error
    else
      xs = Enum.map(points, &elem(&1, 0))
      ys = Enum.map(points, &elem(&1, 1))
      mx = mean(xs)
      my = mean(ys)

      sxx = points |> Enum.map(fn {x, _} -> (x - mx) * (x - mx) end) |> Enum.sum()
      sxy = points |> Enum.map(fn {x, y} -> (x - mx) * (y - my) end) |> Enum.sum()

      if sxx == 0.0 do
        :error
      else
        slope = sxy / sxx
        intercept = my - slope * mx
        {:ok, finish(points, ys, my, slope, intercept, n)}
      end
    end
  end

  def ols(_), do: :error

  defp finish(points, ys, my, slope, intercept, n) do
    sse =
      points
      |> Enum.map(fn {x, y} ->
        residual = y - (slope * x + intercept)
        residual * residual
      end)
      |> Enum.sum()

    sst = ys |> Enum.map(&((&1 - my) * (&1 - my))) |> Enum.sum()

    %{
      slope: slope,
      intercept: intercept,
      r2: if(sst == 0.0, do: 1.0, else: 1.0 - sse / sst),
      n: n,
      # n - 2 et non n : deux degres de liberte sont consommes par la pente et
      # l'ordonnee. Cet ecart-type residuel est ce qui donne son intervalle a
      # la projection de progression.
      residual_sd: if(n > 2, do: :math.sqrt(sse / (n - 2)), else: nil)
    }
  end

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)
end
