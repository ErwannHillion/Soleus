# Soleus

Tableau de bord d'entrainement en course a pied : suivi des seances, modeles
physiologiques, et projection de progression. Les donnees viennent d'une
montre Garmin.

## Ce que fait Soleus

- **Ingestion** des fichiers `.fit` Garmin, idempotente (l'empreinte du
  fichier est la cle : reimporter un export ne cree pas de doublon).
- **Metriques par seance** : charge d'entrainement, TRIMP, facteur
  d'intensite, decouplage aerobie.
- **Courbe vitesse-duree** : meilleur effort sur chaque palier de duree et sur
  chaque distance de course.
- **Modeles** : vitesse critique et reserve anaerobie, exposant d'endurance,
  VDOT, allures d'entrainement derivees.
- **Charge et forme** : modele de Banister (charge chronique, charge aigue,
  forme du jour), taux de montee en charge.
- **Projection** : date a laquelle un objectif devient atteignable, par
  extrapolation de la vitesse critique.

## Mise en route

```sh
docker compose up -d db     # Postgres 17 sur le port 5436
mix deps.get
mix ecto.setup
mix phx.server              # http://localhost:4006
```

Les ports sont volontairement non standards (`5436` pour Postgres, `4006` pour
le serveur) : plusieurs projets coexistent sur la machine de developpement.

### Historique de demonstration

Pour avoir un tableau de bord vivant sans attendre un export Garmin :

```sh
mix run priv/repo/seeds_demo.exs
mix soleus.rebuild
```

Le generateur construit six mois de seances a partir d'une vitesse critique
qui progresse lentement. C'est aussi un test du moteur : si la vitesse
critique ajustee a la fin ne retrouve pas celle injectee au depart, le moteur
a tort.

## Recuperer ses donnees Garmin

Trois chemins, complementaires :

| Source | Contenu | Limites |
| --- | --- | --- |
| **Export RGPD** Garmin Connect | tout l'historique en `.fit` | manuel, a faire une fois |
| **Personal API** Garmin | activites, `.fit`, sommeil, HRV, Body Battery | cle expirable, token 24 h sans rafraichissement, backfill ~30 jours, pas de webhook |
| **API Strava** | flux 1 Hz, webhook, historique complet | donnees retravaillees, ni HRV ni Body Battery ni Running Dynamics |

La combinaison retenue est l'export RGPD pour amorcer l'historique, puis la
Personal API pour l'incremental quotidien.

### Import de l'export RGPD

```sh
unzip -d priv/import/fit <export>/DI_CONNECT/DI-Connect-Uploaded-Files/UploadedFiles_*.zip
mix soleus.import
mix soleus.enrich <export>/DI_CONNECT/DI-Connect-Fitness/*_summarizedActivities.json
mix soleus.rebuild
```

Un export contient surtout des fichiers qui ne sont pas des seances : sur
8 675 fichiers, 131 sont des activites, le reste etant du suivi quotidien et
de la HRV nocturne. L'import les ecarte tout seul.

### Brancher la Personal API

```sh
# 1. creer une cle sur https://connect.garmin.com/app/settings/personalApiToken
#    (elle n'est affichee qu'une seule fois)
# 2. la poser dans .env
echo 'GARMIN_API_KEY=...' >> .env

mix soleus.garmin check     # verifie la cle et interroge un endpoint reel
mix soleus.garmin sync      # synchronise les 7 derniers jours
```

Une fois la cle en place, `Soleus.Workers.SyncGarmin` tourne chaque nuit a
00h10, juste avant le reajustement des modeles.

La cle expire au bout d'un an au plus et Garmin n'emet **pas** de jeton de
rafraichissement : le jour ou elle expire, la synchronisation s'arrete avec un
message explicite et il faut en regenerer une a la main.

## Reconstruire les donnees derivees

```sh
mix soleus.rebuild
```

Recalcule dans l'ordre de dependance : metriques par seance, serie de charge
quotidienne, ajustements historiques des modeles, ajustement du jour.
L'etape des ajustements historiques est celle qu'on oublie : sans elle la
projection n'a aucune pente a extrapoler.

## Notes de conception

Les choix qui ne se devinent pas a la lecture sont commentes a l'endroit ou ils
s'appliquent. Les trois principaux :

- **Les series point par point sont un blob compresse**, pas une ligne par
  echantillon. Une ligne par point donnerait une table a dizaines de millions
  de lignes pour une donnee toujours lue en entier.
  (`Soleus.Training.Stream`)
- **Les predictions longues passent par Riegel, pas par la loi de puissance
  ajustee.** Une courbe de meilleurs efforts tiree de l'entrainement n'est
  maximale que la ou l'athlete a couru fort ; ajuster l'endurance sur des
  sorties longues en footing mesure la lenteur des footings.
  (`Soleus.Analytics.predictions/3`)
- **La serie de charge est reconstruite en entier, jamais mise a jour en
  place.** Les moyennes exponentielles se propagent, donc importer une seance
  ancienne invalide tout ce qui suit. (`Soleus.Analytics.rebuild_daily_loads/0`)
