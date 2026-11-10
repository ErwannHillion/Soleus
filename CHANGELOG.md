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

- Page `Plan` : plan d'entraînement vers une course datée, à partir d'une
  distance, d'un dénivelé et d'un temps cible facultatif. Verdict de
  faisabilité, objectif déduit de la forme quand aucun n'est saisi, et séances
  datées avec leur structure et leurs allures

- Panneau « À regarder » : signaux dérivés des mesures — polarisation de
  l'intensité, montée en charge, rapport aigu/chronique, variabilité
  cardiaque sous la normale, sommeil en baisse, monotonie de Foster
- Répartition du temps par zone de fréquence cardiaque, importée depuis
  l'export Garmin (131 séances) et confrontée au modèle polarisé
- Calendrier de charge : une colonne par semaine, qui révèle les rythmes
  qu'une courbe temporelle masque

- Zones de fréquence cardiaque dérivées des efforts maximaux de l'athlète
  (FC max observée, FC au seuil), comparées à celles de la montre
- Répartition de l'intensité **par allure**, qui ignore l'inertie cardiaque
- Mesure de l'inertie cardiaque : délai avant que la FC rejoigne le régime
  de la séance

- La synchronisation Garmin récupère aussi les données de santé : sommeil,
  HRV, stress, réserve d'énergie, pas, sur une fenêtre de 30 jours
- Les séances synchronisées par l'API reçoivent leur nom et leurs zones de
  fréquence depuis le résumé renvoyé par la recherche
- `mix soleus.garmin sante` et `mix soleus.garmin probe`

- Le tracé et les graphiques d'une séance sont liés : survoler un graphique
  déplace un curseur sur la carte
- Les tours enregistrés par la montre, avec leur intensité (échauffement,
  série, récupération) et le résumé des séries façon « 6 × 400 m à 4:07/km »
- Détails de séance : puissance, cadence, longueur de foulée, temps de contact
  au sol, oscillation verticale, effet d'entraînement
- `mix soleus.laps` relit les tours des séances déjà importées sans tout
  réimporter

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
- Une date de course passée faisait planter la page Plan : `max(-1.0, 0)` rend
  l'entier `0`, que `Float.floor/2` refuse
- La tendance de vitesse critique est désormais calculée à un seul endroit :
  la projection d'objectif et le plan en donnaient deux valeurs différentes
- Le bouton Garmin annonçait « il y a 4 minutes » alors qu'aucune clé n'est
  configurée : l'état se lisait dans l'historique d'Oban, qui enregistrait
  comme terminés des jobs arrêtés faute de clé
- `{:discard, reason}` remplacé par `{:cancel, reason}`, déprécié depuis
  Oban 2.14
- Le signal de polarisation était faux. Il comparait « sous la zone 3 de
  Garmin » (70 % de la FC max) à la frontière du modèle polarisé (premier
  seuil ventilatoire), qui se situe bien plus haut. Sur le même historique il
  annonçait 34 % de temps facile là où la mesure par allure en donne 72 %
- L'estimation de la FC au seuil retenait tous les efforts à l'allure de
  vitesse critique, dont ceux de début de sortie où la FC n'a pas fini de
  monter : elle donnait 166 au lieu de 187. Elle n'utilise plus que les
  efforts maximaux
- La légende de la zone 0 affichait le dernier plancher au lieu d'aucun
