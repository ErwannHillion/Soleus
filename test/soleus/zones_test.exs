defmodule Soleus.ZonesTest do
  use ExUnit.Case, async: true

  alias Soleus.Analytics.Zones

  doctest Soleus.Analytics.Zones

  describe "zone_of/2" do
    test "situe une frequence dans son palier" do
      floors = [150, 159, 168, 178, 187]

      assert Zones.zone_of(120, floors) == 0
      assert Zones.zone_of(150, floors) == 1
      assert Zones.zone_of(167, floors) == 2
      assert Zones.zone_of(177, floors) == 3
      assert Zones.zone_of(186, floors) == 4
      assert Zones.zone_of(195, floors) == 5
    end
  end

  describe "easy_pace_share/1" do
    test "ne compte que la bande la plus lente" do
      # La zone grise — entre allure marathon et allure seuil — n'est pas du
      # facile. L'y inclure gonflerait le chiffre et flatterait la lecture.
      assert Zones.easy_pace_share([700, 100, 100, 100]) == 70.0
      assert Zones.grey_pace_share([700, 100, 100, 100]) == 10.0
    end

    test "rend nil sans donnee plutot que zero" do
      # Zero se lirait comme « rien de facile », ce qui est une affirmation,
      # alors qu'on ne sait rien.
      assert Zones.easy_pace_share([0, 0, 0, 0]) == nil
    end
  end

  describe "easy_share/3" do
    test "compte les zones sous la frontiere du facile" do
      floors = [150, 159, 168, 178, 187]
      # Frontiere a 168 : les zones 0, 1 et 2 sont en dessous.
      zones = [100, 200, 300, 200, 100, 100]

      assert_in_delta Zones.easy_share(zones, 168, floors), 600 / 1000 * 100, 0.001
    end

    test "sans frontiere connue, ne tranche pas" do
      assert Zones.easy_share([100, 100], nil, [150]) == nil
    end
  end
end
