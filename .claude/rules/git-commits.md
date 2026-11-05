# Règles de commit

## Nomenclature

**Format** : `type(scope): description`

Pas de préfixe de ticket : Soleus est un projet personnel sans suivi Jira.

### Exemples

- `feat(analytics): ajoute le modèle de vitesse critique à deux paramètres`
- `fix(mean-maximal): interpole la FC au lieu de compter les trous comme des zéros`
- `refacto(charts): extrait le rééchantillonnage partagé entre distance et FC`
- `ops(docker): passe Postgres sur le port 5436`

## Types autorisés

- `feat` — nouvelle fonctionnalité
- `fix` — correction de bug
- `refacto` — refactoring sans changement de comportement
- `test` — ajout ou modification de tests
- `docs` — documentation
- `style` — formatage, sans changement logique
- `chore` — maintenance
- `ops` — configuration, déploiement

## Scopes usuels

`ingest`, `training`, `analytics`, `charts`, `dashboard`, `workers`, `db`,
`docker`, `deps`.

## Identité

**Identité personnelle, locale au dépôt** :

```
SHDXW <150029027+ErwannHillion@users.noreply.github.com>
```

Elle est déjà posée dans `.git/config`. Ne **jamais** commiter avec
`infrastructure@inter-gestion.com` ni `erwann.hillion@inter-gestion.com` :
ce sont les identités professionnelles, et ce dépôt est personnel.

Vérifier avant le premier commit d'une session :

```bash
git config --local user.email   # 150029027+ErwannHillion@users.noreply.github.com
```

## Règles strictes

❌ **Interdit** :
- mentionner Claude, Claude Code, ou toute référence à une IA
- un trailer `Co-Authored-By`
- des emojis
- l'email professionnel

✅ **Obligatoire** :
- message en français
- description concise, à l'impératif ou au présent
- corps du commit pour le *pourquoi*, pas pour la liste des fichiers

## Format du corps

Le titre dit ce qui change. Le corps dit pourquoi, et ce qu'il fallait savoir
pour le faire.

```
fix(mean-maximal): interpole la FC entre deux points de mesure

L'enregistrement intelligent de Garmin espace les points. La grille comblait
la distance par interpolation mais remplissait la FC de zéros, ce qui divisait
la FC moyenne de chaque effort record par le pas d'échantillonnage — des
valeurs à 30 bpm sur une séance à 150.

Les deux séries passent maintenant par le même rééchantillonneur.
```

## Avant chaque commit

1. `git branch --show-current`
2. `git status` puis `git diff`
3. `mix format`
4. `mix credo --strict` — doit être vert, sans exception
5. `mix test`
6. Si une variable d'environnement ou un service externe apparaît : mettre à
   jour `README.md` et `.claude/rules/project-specific.md`
7. Mettre à jour `CHANGELOG.md` sous `[Unreleased]`
