# Changelog

Toutes les modifications notables de ce projet sont documentées dans ce
fichier, au format [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/).

## [Unreleased]

### Added

- Ingestion idempotente des fichiers FIT Garmin, via le NIF Rust `fit_file`
- Métriques par séance : charge d'entraînement, TRIMP, facteur d'intensité,
  découplage aérobie
- Courbe vitesse-durée : meilleur effort par palier de durée et par distance de
  course, sur grille rééchantillonnée à 1 Hz
- Modèle de vitesse critique à deux paramètres, exposant d'endurance
  personnalisé, VDOT et allures d'entraînement dérivées
- Charge et forme : modèle de Banister matérialisé, taux de montée en charge
- Prédictions de temps de course et projection de la date à laquelle un
  objectif rond devient atteignable
- Tableau de bord LiveView, graphes en SVG généré côté serveur
- Générateur d'historique de démonstration, qui sert aussi de test du moteur
- Tâche `mix soleus.rebuild`
- Dix checks Credo maison branchés par `.credo.exs`

- Import de masse `mix soleus.import` d'un export RGPD Garmin, et
  `mix soleus.enrich` pour poser les noms de séance depuis le résumé JSON

### Fixed

- FC moyenne des efforts records sur les fichiers à enregistrement intelligent :
  les secondes sans mesure étaient comptées comme des zéros, divisant la moyenne
  par le pas d'échantillonnage
- Prédictions longues extrapolées par Riegel plutôt que par la loi de puissance
  ajustée, qui mesurait la lenteur des sorties longues
- Projection et tableau des prédictions utilisent la même cascade de modèles et
  ne peuvent plus se contredire
- Clés de série déclarées dans `Training.Stream`, pour que le décodage `:safe`
  ne dépende plus de l'ordre de chargement des modules
- Un sport FIT non reconnu retombe sur `unknown` au lieu de faire échouer
  l'import sur la validation du changeset
- Les fichiers d'accumulation multi-jours de Garmin (marqués `generic`, jusqu'à
  893 km sur 5 jours) sont écartés : ils portent un message `session` valide
  mais produisaient une charge de plusieurs milliers de points qui écrasait la
  courbe de forme
- `sample_count` d'un ajustement compte les points du modèle, pas la longueur
  de la courbe
- `startTimeGmt` de l'export Garmin est un flottant, ce qui faisait échouer
  silencieusement tous les appariements de noms
