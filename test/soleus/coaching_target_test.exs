defmodule Soleus.CoachingTargetTest do
  use ExUnit.Case, async: true

  alias Soleus.Coaching.Target

  doctest Soleus.Coaching.Target

  describe "parse/1" do
    test "accepte les tournures qu'un coureur emploie" do
      assert Target.parse("sub 50") == {:ok, 3000}
      assert Target.parse("SUB50") == {:ok, 3000}
      assert Target.parse("sous 50") == {:ok, 3000}
      assert Target.parse("< 50") == {:ok, 3000}
      assert Target.parse("50 min") == {:ok, 3000}
    end

    test "accepte les formats horaires" do
      assert Target.parse("49:30") == {:ok, 2970}
      assert Target.parse("1h45") == {:ok, 6300}
      assert Target.parse("1h45m30") == {:ok, 6330}
      assert Target.parse("3:30:00") == {:ok, 12_600}
      assert Target.parse("22:49") == {:ok, 1369}
    end

    test "distingue une saisie vide d'une saisie invalide" do
      # Vide veut dire « calcule pour moi », pas « erreur » : c'est le cas le
      # plus utile, et le traiter comme une faute serait hostile.
      assert Target.parse("") == :none
      assert Target.parse("   ") == :none
      assert Target.parse(nil) == :none

      assert Target.parse("vite") == :error
      assert Target.parse("0") == :error
    end
  end

  describe "effective_distance/2" do
    test "convertit le denivele en distance equivalente" do
      assert Target.effective_distance(10_000, 150) == 11_500.0
      assert Target.effective_distance(10_000, 0) == 10_000.0
      assert Target.effective_distance(10_000, nil) == 10_000.0
    end
  end
end
