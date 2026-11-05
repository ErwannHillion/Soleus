# Changelog Rules

## Objectif

Maintenir un suivi des fonctionnalités livrées pour préparer les releases.

## Format

Le fichier `CHANGELOG.md` se trouve à la racine du projet.

Format : [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/)

```markdown
# Changelog

Toutes les modifications notables de ce projet seront documentées dans ce fichier.

## [Unreleased]

### Added
- Nouvelle fonctionnalité X pour [contexte]
- Nouveau module Y pour gérer [cas d'usage]

### Changed
- Amélioration de Z pour [raison]
- Refactorisation de W pour [bénéfice]

### Fixed
- Correction du bug A dans [contexte]
- Résolution du problème B causé par [raison]

### Removed
- Suppression de la feature obsolète C

## [1.2.0] - 2025-01-15

### Added
- Ingestion idempotente des fichiers FIT Garmin
- Charge d'entraînement et modèle de Banister

...
```

## Workflow

### Avant Chaque PR

**TOUJOURS** mettre à jour le `CHANGELOG.md` dans la section `[Unreleased]`.

```bash
# 1. Identifier les changements principaux de la PR
# 2. Les ajouter dans CHANGELOG.md sous [Unreleased]
# 3. Commit avec les autres changements
```

### Catégories

- **Added** : Nouvelles fonctionnalités
- **Changed** : Modifications de fonctionnalités existantes
- **Fixed** : Corrections de bugs
- **Removed** : Fonctionnalités supprimées
- **Deprecated** : Fonctionnalités dépréciées (à supprimer prochainement)
- **Security** : Corrections de sécurité

### Style

✅ **Bon** - Concis et orienté métier :
```markdown
### Added
- Modèle de vitesse critique à deux paramètres, avec les allures dérivées
- Projection de la date à laquelle un objectif devient atteignable
- Courbe vitesse-durée sur fenêtre glissante de 90 jours

### Fixed
- FC moyenne des efforts records sur les fichiers à enregistrement intelligent
- Prédictions longues calées sur Riegel quand la courbe n'est pas maximale
```

❌ **Mauvais** - Trop technique ou verbeux :
```markdown
### Added
- Ajout de la fonction predict_distance/4 dans Soleus.Analytics ligne 312 qui appelle CriticalSpeed.predict/2 quand la durée obtenue est inférieure à @cs_max_duration, sinon Endurance.riegel/4 avec l'exposant stocké dans model_fits.endurance_exponent
```

## Remaniement du Changelog

Si la section `[Unreleased]` devient trop longue ou verbeuse :
- Regrouper les changements similaires
- Simplifier les descriptions
- Supprimer les détails trop techniques

**Moment idéal** : Juste avant une release.

## Exemple Complet

```markdown
# Changelog

## [Unreleased]

### Added
- Dock de navigation en bas d'écran
- Records personnels par distance de course

### Changed
- Prédictions longues extrapolées par Riegel au lieu de la loi de puissance

### Fixed
- Projection et tableau des prédictions utilisent la même cascade de modèles

## [1.5.0] - 2025-01-20

### Added
- Décodage des fichiers FIT via le NIF Rust fit_file

### Fixed
- Clés de série déclarées dans Stream, pour un décodage `:safe` fiable

## [1.4.0] - 2025-01-10

...
```

## Intégration avec PRs

Le changelog peut être référencé dans le corps de la PR :

```markdown
## Résumé
Ajout du modèle de vitesse critique et des prédictions de temps de course.

## Changements
Voir CHANGELOG.md section [Unreleased]

## Test plan
- [ ] `mix run priv/repo/seeds_demo.exs && mix soleus.rebuild`
- [ ] Vérifier que la vitesse critique ajustée retrouve celle injectée
- [ ] Vérifier que projection et prédictions ne se contredisent pas
```

## Notes

- Le changelog est un **document vivant**
- Il peut être remanié avant chaque release
- Il sert de base pour les notes de release
- Il aide à communiquer les changements aux utilisateurs
