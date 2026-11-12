# Soleus

Tableau de bord d'entraînement en course à pied sur données Garmin.
Phoenix 1.8 / LiveView, Postgres, Oban. Projet **personnel et privé** : un
seul athlète, pas d'authentification, pas de multi-tenant.

Dépôt privé `ErwannHillion/Soleus`. Identité de commit `SHDXW
<150029027+ErwannHillion@users.noreply.github.com>`, **jamais** l'email
professionnel, **aucune mention d'IA ni de `Co-Authored-By`**.

## Démarrer

```sh
docker compose up -d db     # Postgres 17 sur le port 5436
mix ecto.setup
mix phx.server              # http://localhost:4006
```

Ports volontairement non standards : plusieurs projets cohabitent sur la
machine. Le port du serveur se change dans **`config/runtime.exs`** et non
dans `dev.exs` — voir les pièges plus bas.

## Règles

Lire `.claude/rules/` avant de travailler. Les plus structurants :

| Fichier | Contenu |
|---|---|
| `project-specific.md` | architecture, trois échelles de temps du moteur, pièges |
| `elixir-code.md` | pas d'assertion par match sur une donnée d'entrée |
| `configuration.md` | `System.get_env` seulement dans `config/*.exs`, lecture par `Soleus.Config` |
| `database.md` | migrations, upserts, spécificités du schéma |
| `git-commits.md` | nomenclature `type(scope)`, identité, aucune mention d'IA |
| `chrome-headless.md` | nettoyer les Chrome headless et le port 4006 |
| `changelog.md` | `CHANGELOG.md` sous `[Unreleased]` |

## Avant de rendre la main

1. `mix format`
2. `mix credo --strict` — **vert**, les dix checks de `.credo/` sont branchés
3. `mix test`
4. `CHANGELOG.md` à jour sous `[Unreleased]`
5. Aucun Chrome headless ni serveur de dev laissé derrière
   (`./scripts/kill-headless-chrome.sh`, `lsof -nP -iTCP:4006 -sTCP:LISTEN`)

## Les données

Historique réel importé : **134 activités** (101 courses) de juin 2025 à
novembre 2026, **1 325 tours**, **512 jours** de mesures de santé.

Source : export RGPD dans `~/Documents/data_garmin`. L'API personnelle Garmin
prendra le relais pour l'incrémental dès qu'une clé sera posée dans `.env`.

```sh
# amorcage depuis l'export RGPD
unzip -d priv/import/fit <export>/DI_CONNECT/DI-Connect-Uploaded-Files/UploadedFiles_*.zip
mix soleus.import                                   # seances
mix soleus.enrich <export>/.../*_summarizedActivities.json   # noms, zones, details
mix soleus.wellness <export>/DI_CONNECT             # sommeil, HRV, stress...
mix soleus.laps                                     # tours et series, sans reimport
mix soleus.rebuild                                  # metriques, charge, modeles

# API personnelle
mix soleus.garmin check     # la cle donne-t-elle un jeton, l'API repond-elle ?
mix soleus.garmin sync      # seances (7 j)
mix soleus.garmin sante     # sante (30 j)
mix soleus.garmin probe     # forme brute des reponses, a confronter a la traduction
```

## Architecture

| Contexte | Rôle |
|---|---|
| `Soleus.Training` | séances, séries, tours, efforts records, athlète |
| `Soleus.Health` | mesures quotidiennes hors séance |
| `Soleus.Analytics` | métriques, charge, modèles, projections |
| `Soleus.Coaching` | faisabilité d'un objectif, plan d'entraînement |
| `Soleus.Signals` | ce qui sort de l'ordinaire aujourd'hui |
| `Soleus.Ingest.*` | FIT, export RGPD, API personnelle Garmin |
| `Soleus.Sync` | déclenchement et suivi de la synchronisation |

`Analytics` dépend de `Training`, jamais l'inverse.

Pages : accueil, forme, séances, séance, courbe, corps, comparer, plan,
prédictions. Navigation par **dock macOS en bas**, vues plein écran.

## Direction artistique

Sombre, dense, esprit instrument de mesure — explicitement **pas** « un truc
IA revu et revu ». Le **violet est une couleur de signal, jamais un fond**.
Chiffres en chasse fixe (`.num`), séparations en filets d'un pixel, pas
d'ombres. Graphiques en SVG généré en Elixir ; le seul JS est trois hooks —
survol, sélection de zone, carte Leaflet.

## Les pièges, et pourquoi ils existent

Ce sont les erreurs réellement commises sur ce projet. Les relire évite de
les refaire.

**Le port du serveur vit dans `config/runtime.exs`.** Ce fichier s'applique à
tous les environnements depuis Phoenix 1.8 et est évalué après `dev.exs` : son
défaut `PORT=4000` écrasait le 4006 posé dans `dev.exs`. Vérifier la valeur
**effective**, jamais le fichier.

**`mix compile` ne détecte pas un `attr` manquant sur un composant.** Seul le
rendu le révèle. Vérifier les routes après chaque changement de composant.

**Garmin est incohérent avec son propre export.** `calendarDate` est une
chaîne ISO dans les fichiers de santé et un entier en millisecondes dans ceux
de charge ; `startTimeGmt` est un flottant ; le résumé d'activité n'emploie
pas la même échelle de vitesse que le fichier FIT (0,283 contre 2,83 m/s).
Ne jamais supposer une forme — la vérifier.

**L'intensité `interval` de Garmin ne veut pas dire « série ».** C'est la
valeur par défaut des tours automatiques : 761 tours la portent avec un
déclencheur `distance`, ce sont les kilomètres des footings. Seul `active`
désigne une vraie série.

**La correction de pente de Garmin est inexploitable sans altitude.** Le
champ est renseigné même quand aucun altimètre n'a tourné, avec des valeurs
qui donneraient 30 % de correction sur du plat.

**Ne jamais écrire `nil` a une contrepartie.** La règle protège contre
l'écrasement par une source partielle, mais empêche une correction d'effacer
une valeur fausse déjà posée. Vider la colonne avant de rejouer.

**La polarisation se mesure par l'allure, pas par la fréquence cardiaque.**
Chez cet athlète la FC met en médiane 5 min 20 — et plus de 11 minutes sur un
quart des sorties — à rejoindre le régime de la séance. Une fenêtre de 15 min
à 5:23/km a été relevée à 125 bpm. Les zones de la montre, découpées en
pourcentage de FC max, placent en outre la frontière Z2/Z3 bien sous le
premier seuil : l'ancienne mesure annonçait 34 % de temps facile là où
l'allure en donne 72 %.

**Comparer deux calculs d'une même grandeur avant de livrer.** Deux défauts
de ce type ont été corrigés : projection contre prédictions, puis tendance de
vitesse critique entre la projection et le plan. Deux chiffres contradictoires
à l'écran coûtent plus cher que la précision théorique gagnée.

**Tailwind peut être tué par SIGKILL sur ce Mac** (exit 137, aucun CSS).
`codesign -f -s - _build/tailwind-macos-arm64-*` puis relancer.

## Le générateur de démonstration est un test du moteur

`priv/repo/seeds_demo.exs` construit les séances à partir d'une vitesse
critique qui progresse lentement. **Si la VC ajustée ne retrouve pas celle
injectée, c'est le moteur qui a tort.**

```sh
mix ecto.reset && mix run priv/repo/seeds_demo.exs && mix soleus.rebuild
```

La valeur injectée en fin de période est `cs_end` dans ce fichier.
