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

- Client de l'API personnelle Garmin : échange de clé contre jeton avec
  renouvellement avant échéance, recherche d'activités, téléchargement du
  fichier d'origine, synchronisation Oban quotidienne et `mix soleus.garmin`

- Import des données de santé quotidiennes (`mix soleus.wellness`) : sommeil,
  HRV, FC au repos, respiration, stress, réserve d'énergie, pas, VO2max,
  charge Garmin — 512 jours, avec les lignes de base personnelles
- Page `Corps` : schéma corporel dont chaque région porte l'état d'un système,
  cartes par mesure, comparaison à la période précédente
- Sélection de période (30 j à tout) et **sélection d'une zone au curseur** sur
  le graphique de charge
- Filtre par sport sur la liste des séances

- Page d'accueil : vue d'ensemble reprenant forme, charge, état du jour,
  modèle, prédictions et dernières séances
- Vue détail d'une séance : tracé GPS, allure, fréquence cardiaque, altitude et
  portions kilométriques
- **Lecture au survol** sur tous les graphiques : date et valeurs de chaque
  série, résolues côté client
- Phases de sommeil en graphe empilé
- Comparaison de deux périodes arbitraires côte à côte
- Confrontation de la charge chronique de Soleus à celle de Garmin, avec leur
  corrélation

- Fond de carte OpenStreetMap sur le tracé GPS d'une séance, via Leaflet servi
  localement

- Bouton « Garmin » dans l'interface pour récupérer les séances à la demande,
  avec l'avancement en direct, et rattrapage automatique au démarrage de
  l'application

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
- `calendarDate` est un entier en millisecondes dans trois familles de
  l'export Garmin et une chaîne ISO dans les autres : les charges aiguës,
  scores d'endurance et scores en côte n'étaient silencieusement jamais
  importés
- L'état de santé se reconstitue sur une fenêtre de quatorze jours plutôt que
  sur la seule dernière ligne : toutes les mesures n'arrivent pas le même jour,
  et la charge d'entraînement du jour affichait un tiret
- Le schéma corporel était une silhouette en capsules qui ne ressemblait pas à
  un corps ; refait en tracé anatomique, chaque partie posée sur un fond opaque
  pour que les recouvrements ne laissent plus voir ce qui passe dessous
- Les distances de la comparaison s'affichaient en mètres
- L'échelle des barres de portions va de la plus lente à la plus rapide : sur
  une sortie régulière, rapportées à zéro, elles étaient toutes identiques
