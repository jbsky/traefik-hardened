#!/usr/bin/env bash
# =====================================================================
#  journal.sh -- lire le journal d'un conteneur, sans tuyau
#
#  Sourcable, aucun effet de bord : scripts/test.sh s'en sert, et
#  scripts/test_journal.sh l'eprouve en remplacant `journal`.
#
#  Pourquoi un fichier pour deux fonctions : `docker logs ... | grep -q`
#  est un piege. `grep -q` sort a la PREMIERE correspondance et ferme le
#  tuyau ; s'il reste des octets a ecrire, `docker logs` meurt de SIGPIPE
#  (141) et, sous `pipefail`, le pipeline ECHOUE alors que le motif EST
#  present. Echec aleatoire vecu le 2026-10-22 (run 39784521199) : la
#  sonde des plugins a rendu ECHEC sur un avertissement bien emis -- la
#  meme orniere que haproxy-hardened PR #2, deja consignee dans le
#  Dockerfile. On capture d'abord, on cherche ensuite.
# =====================================================================

# journal <conteneur> -- le journal complet, d'un seul coup.
#
# Une erreur de `docker logs` (conteneur disparu) part dans la capture au
# lieu d'arreter l'appelant : c'est l'assertion qui tranche, avec son
# message, pas un `set -e` muet.
#
# Remplacable : test_journal.sh la redefinit pour eprouver
# `journal_contient` sans conteneur, comme init.go rend `isSubcommand`
# remplacable pour ses tests.
journal() { docker logs "$1" 2>&1 || true; }

# journal_contient <conteneur> <motif> -- vrai si le journal porte le motif
# (chaine litterale, jamais une expression).
journal_contient() {
  local texte
  texte=$(journal "$1")
  grep -qF -- "$2" <<<"$texte"
}
