#!/usr/bin/env bash
# =====================================================================
#  test_journal.sh -- sonde unitaire de scripts/journal.sh
#
#  Criteres :
#    1. un motif present est trouve, meme quand l'ecrivain du journal a
#       encore beaucoup a dire apres lui ;
#    2. un motif absent est bien refuse (la sonde garde son pouvoir de
#       dire non) ;
#    3. la variante fautive -- `journal <conteneur> | grep -q <motif>` --
#       ECHOUE sur le critere 1 : c'est la preuve que cette sonde tombe
#       sur le defaut vise (SIGPIPE sous `pipefail`) et pas ailleurs.
#
#  Aucun conteneur : `journal` est remplacee par un ecrivain bavard.
#  scripts/test.sh lance cette sonde avant ses propres tests.
# =====================================================================
set -euo pipefail

ICI=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=journal.sh
. "$ICI/journal.sh"

ECHEC=0
oki() { printf '  OK     %s\n' "$*"; }
koi() { printf '  ECHEC  %s\n' "$*" >&2; ECHEC=1; }

MOTIF="WARNING: /plugins-storage n'est pas inscriptible"

# Le journal du conteneur fautif, en vrai : le motif est la PREMIERE ligne,
# suivie de bien plus que la taille d'un tuyau (64 Kio) -- c'est ce qui
# donne a l'ecrivain de quoi mourir de SIGPIPE.
bavard() {
  printf '[init] %s par l uid 65532 -- un plugin ne pourra pas s y installer\n' "$MOTIF"
  seq 1 200000
}

# La variante fautive, celle d'avant : un seul defaut injecte, le tuyau.
mutation_contient() { journal "$1" | grep -qF -- "$2"; }

# --- critere 1 : le motif present est trouve -------------------------
journal() { bavard; }
code=0
journal_contient bavard "$MOTIF" || code=$?
if [ "$code" = 0 ]; then
  oki "motif present trouve dans un journal bavard"
else
  koi "motif present declare absent (code $code) : la capture passe par un tuyau ?"
fi

# --- critere 2 : le motif absent est refuse --------------------------
journal() { printf 'rien a signaler\n'; }
if journal_contient bavard "$MOTIF"; then
  koi "un motif absent a ete declare present : la sonde ne refuse plus rien"
else
  oki "motif absent refuse"
fi

# --- critere 3 : la mutation echoue sur le critere 1 -----------------
journal() { bavard; }
code=0
mutation_contient bavard "$MOTIF" || code=$?
if [ "$code" = 0 ]; then
  koi "la mutation (| grep -q) passe : cette sonde ne prouve rien du defaut vise"
else
  oki "mutation refusee (code $code) : le defaut vise est bien le tuyau"
fi

[ "$ECHEC" = 0 ] || { printf 'sonde journal : ECHEC\n' >&2; exit 1; }
printf 'sonde journal : les 3 criteres tiennent\n'
