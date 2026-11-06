#!/bin/sh
# go-overrides-apply.sh -- applique ou verifie go-overrides.json au build
# (cf. SECURITY.md, scripts/go-cve-autofix.js). `apply` tourne juste apres le
# COPY des sources de l'amont, AVANT `go build` : force chaque module a la
# version corrigee via `go get` (integrite par go.sum + sum.golang.org,
# jamais une edition a la main de go.sum). `verify` tourne APRES `go build` :
# `go version -m` lit exactement le meme buildinfo que Trivy (cf.
# go-cve-watch.yml), donc la preuve la plus proche du defaut qu'une CVE Go
# corrige.
#
# apply ne force JAMAIS une retrogradation : un override devenu inutile
# (l'amont a deja adopte cette version ou plus -- par exemple apres une
# montee manuelle de versions.json qui aurait oublie de retirer l'entree)
# est ignore, jamais applique a l'envers. La ligne reste dans
# go-overrides.json jusqu'au prochain passage de go-cve-autofix.js, qui ne
# la reecrit plus -- a retirer a la main si elle ne sert plus a rien.
#
#   go-overrides-apply.sh apply  <go-overrides.json>
#   go-overrides-apply.sh verify <go-overrides.json> <binaire>
set -eu

mode="${1:?usage: go-overrides-apply.sh apply|verify <go-overrides.json> [binaire]}"
file="${2:?go-overrides.json requis}"

cles() { jq -r 'keys[]' "$file"; }
version_de() { jq -r --arg k "$1" '.[$k].version' "$file"; }

# Tri de version simple (X.Y.Z, sans "v") : suffisant quand les deux membres
# viennent de go-cve-autofix.js (semver strict -- cf. son parseSemver). Une
# entree posee a la main pour un correctif en pseudo-version Go (issue
# [go-cve], ex. knative.dev/pkg) n'est PAS comparee correctement ici : les
# trois champs numeriques valent "0.0.0" pour toute pseudo-version sans tag
# anterieur, donc le tri les trouve a egalite et ne depart que par l'ordre
# d'entree (stable) -- qui renvoie toujours le second argument. Fonctionne
# seulement parce que ce script appelle toujours plus_recente(actuelle, cible),
# jamais l'inverse : une future majoration de l'amont au-dela de la cible ne
# serait PAS detectee comme rendant l'override inutile (pas de retrogradation
# ici, mais la garde qui l'evite ailleurs ne vaut rien sur ce cas). A retirer
# a la main si l'amont depasse un jour la pseudo-version forcee.
plus_recente() {
    printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

case "$mode" in
  apply)
    cles | while IFS= read -r module; do
      [ -n "$module" ] || continue
      version=$(version_de "$module")
      actuelle=$(go list -m -f '{{.Version}}' "$module" 2>/dev/null | sed 's/^v//')
      if [ -z "$actuelle" ]; then
        echo "override ${module} : module introuvable dans l'arbre, ignore" >&2
        continue
      fi
      if [ "$actuelle" = "$version" ] || [ "$(plus_recente "$actuelle" "$version")" = "$actuelle" ]; then
        echo "override ${module} : amont deja en ${actuelle} (>= ${version}), devenu inutile -- ignore"
        continue
      fi
      echo "override ${module} : ${actuelle} -> ${version}"
      go get "${module}@v${version}"
    done
    ;;
  verify)
    # Interroge le BINAIRE directement (`go version -m`, meme buildinfo que
    # Trivy) -- jamais `go list -m` sur l'arbre source : rien ne garantit que
    # ce stage y soit encore (et ce n'est pas la question posee).
    binaire="${3:?binaire requis pour verify}"
    cles | while IFS= read -r module; do
      [ -n "$module" ] || continue
      version=$(version_de "$module")
      actuelle=$(go version -m "$binaire" | awk -F '\t' -v m="$module" '$2 == "dep" && $3 == m { print $4 }' | sed 's/^v//')
      if [ -z "$actuelle" ]; then
        echo "module absent du binaire : ${module}" >&2
        exit 1
      fi
      if [ "$actuelle" != "$version" ] && [ "$(plus_recente "$actuelle" "$version")" != "$actuelle" ]; then
        echo "override non applique sur le binaire : ${module} attendu >= v${version}, trouve v${actuelle}" >&2
        exit 1
      fi
      echo "verifie sur le binaire : ${module} v${actuelle} (>= v${version} attendu)"
    done
    ;;
  *)
    echo "usage: go-overrides-apply.sh apply|verify <go-overrides.json> [binaire]" >&2
    exit 2
    ;;
esac
