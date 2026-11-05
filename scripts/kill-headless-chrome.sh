#!/usr/bin/env bash
# Ferme les Chrome headless laisses par ChromicPDF.
#
# `mix test` et `mix run` se terminent par un halt qui ne deroule pas l'arret
# des applications : ChromicPDF n'a pas l'occasion de refermer Chrome, et
# chaque execution en laisse quelques-uns. La configuration reduit la fuite
# a ~4 processus par execution, pas a zero — au bout de quelques centaines
# d'executions, la machine s'en ressent (on a mesure 494 processus et 11,6 Go).
#
# Le filtre porte sur le binaire de Chrome ET sur `--headless` : le
# navigateur interactif n'est jamais touche.
set -euo pipefail

cibles=$(ps -axo pid=,args= | awk '/Google Chrome\.app/ && /--headless/ {print $1}' || true)

if [ -z "$cibles" ]; then
  echo "Aucun Chrome headless en cours."
  exit 0
fi

nombre=$(echo "$cibles" | wc -l | tr -d ' ')
memoire=$(ps -o rss= -p "$(echo "$cibles" | tr '\n' ',' | sed 's/,$//')" 2>/dev/null |
  awk '{s+=$1} END {printf "%.1f", s/1024/1024}')

echo "$nombre processus headless, ${memoire} Go."
echo "$cibles" | xargs kill 2>/dev/null || true
sleep 2

restants=$(ps -axo pid=,args= | awk '/Google Chrome\.app/ && /--headless/ {print $1}' || true)
if [ -n "$restants" ]; then
  echo "$restants" | xargs kill -9 2>/dev/null || true
  sleep 1
fi

echo "Termine. Navigateur interactif : $(pgrep -x 'Google Chrome' >/dev/null && echo intact || echo absent)."
