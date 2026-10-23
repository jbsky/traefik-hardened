#!/usr/bin/env bash
# =====================================================================
#  test.sh <image> -- tests fonctionnels de traefik-hardened
#
#  Lance l'image comme en production (chart Helm sur k3s) : rootfs en lecture
#  seule, aucune capacite, no-new-privileges, uid 65532, volumes en tmpfs,
#  configuration montee en lecture seule. Prouve ce que l'image doit savoir
#  faire, pas seulement qu'un port est ouvert :
#    1. le healthcheck de l'image (/ping) ;
#    2. l'API expose la version que le tag annonce ;
#    3. le DASHBOARD est bien embarque (reconstruit depuis les sources) ;
#    4. un routage complet entryPoint -> routeur -> service ;
#    5. une terminaison TLS reelle, avec le certificat fourni ;
#    6. aucun shell, aucune bibliotheque partagee, un uid non nul ;
#    7. une configuration cassee EMPECHE le demarrage ;
#    8. sans volume inscriptible, l'init DIT pourquoi un plugin echouerait.
#
#  Avant tout cela, scripts/test_journal.sh eprouve l'outil qui lit les
#  journaux des conteneurs : un faux ECHEC de cette sonde a deja fait
#  passer une image saine pour cassee (2026-10-22).
# =====================================================================
set -euo pipefail

ICI=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=journal.sh
. "$ICI/journal.sh"

IMAGE="${1:?usage: test.sh <image>}"
NOM="traefik-test-$$"
TMP=$(mktemp -d)
chmod 755 "$TMP"
trap 'docker rm -f "$NOM" "$NOM-ko" "$NOM-plug" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

ok() { printf '  OK     %s\n' "$*"; }
# ko <message> [conteneur] -- le journal verse est celui du conteneur FAUTIF.
# Sans deuxieme argument c'est le conteneur principal. Le dire a l'appel,
# sinon un echec sur "$NOM-ko" ou "$NOM-plug" se lit avec le journal d'un
# conteneur qui, lui, va bien : le run 39784521199 avait l'air de manquer
# l'avertissement des plugins, il montrait juste un autre conteneur.
ko() {
  printf '  ECHEC  %s\n' "$1" >&2
  local cible=${2:-$NOM}
  printf '  -- journal de %s (30 dernieres lignes) --\n' "$cible" >&2
  journal "$cible" | tail -30 >&2
  exit 1
}
# `$(...)` puis coupe a la premiere ligne, jamais `| head -1` : head sort
# des la premiere ligne et l'ecrivain meurt de SIGPIPE (141), fatal sous
# `pipefail` -- meme piege que `| grep -q` (cf. scripts/journal.sh).
premiere_ligne() { printf '%s' "${1%%$'\n'*}"; }

# L'outil de lecture de journal d'abord : c'est lui qui a rendu un faux
# ECHEC le 2026-10-22, et il porte la sonde des plugins plus bas.
"$ICI/test_journal.sh"

VERSION=$(python3 -c 'import json;print(json.load(open("versions.json"))["traefik"])')

# Certificat jetable pour la terminaison TLS.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=test.local" \
  -keyout "$TMP/test.key" -out "$TMP/test.crt" >/dev/null 2>&1
chmod 644 "$TMP/test.key" "$TMP/test.crt"

cat > "$TMP/traefik.yml" <<'CFG'
global:
  checkNewVersion: false
  sendAnonymousUsage: false
entryPoints:
  web:
    address: ":8000"
  websecure:
    address: ":8443"
  traefik:
    address: ":8080"
ping:
  entryPoint: traefik
api:
  dashboard: true
  # Essai seulement : l'API et le dashboard sans authentification, sur la
  # boucle locale du conteneur.
  insecure: true
providers:
  file:
    filename: /etc/traefik/dynamic.yml
log:
  level: INFO
accessLog: {}
CFG

cat > "$TMP/dynamic.yml" <<'CFG'
http:
  routers:
    proxy:
      rule: "Host(`proxy.test`)"
      entryPoints:
        - web
      service: ping-backend
    proxy-tls:
      rule: "Host(`proxy.test`)"
      entryPoints:
        - websecure
      service: ping-backend
      tls: {}
  services:
    ping-backend:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8080/"
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/test.crt
        keyFile: /etc/traefik/test.key
CFG
chmod 644 "$TMP"/*.yml

run() { # <nom> <repertoire de conf> [options docker supplementaires...]
  local nom=$1 conf=$2; shift 2
  docker run -d --name "$nom" \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --user 65532:65532 \
    --tmpfs /tmp:mode=1777 \
    --tmpfs /data:mode=0750,uid=65532,gid=65532 \
    --tmpfs /plugins-storage:mode=0750,uid=65532,gid=65532 \
    -v "$conf:/etc/traefik:ro" \
    -p 127.0.0.1::8000 -p 127.0.0.1::8443 -p 127.0.0.1::8080 \
    "$@" \
    "$IMAGE" traefik --configFile=/etc/traefik/traefik.yml >/dev/null
}

echo "== $IMAGE"
run "$NOM" "$TMP"
for _ in $(seq 1 30); do
  docker exec "$NOM" /usr/local/bin/init --healthcheck >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$NOM" /usr/local/bin/init --healthcheck >/dev/null 2>&1 || ko "healthcheck (/ping)"
ok "healthcheck de l'image (/ping)"

API=$(premiere_ligne "$(docker port "$NOM" 8080/tcp)")
WEB=$(premiere_ligne "$(docker port "$NOM" 8000/tcp)")
TLS=$(premiere_ligne "$(docker port "$NOM" 8443/tcp)")

[ "$(curl -fsS --noproxy '*' -o /dev/null -w '%{http_code}' "http://$API/ping")" = 200 ] || ko "/ping"
ok "/ping repond 200 depuis l'hote"

VU=$(curl -fsS --noproxy '*' "http://$API/api/version")
grep -q "\"Version\":\"${VERSION}\"" <<<"$VU" || ko "/api/version ne dit pas ${VERSION} : $VU"
ok "/api/version = ${VERSION}"

# Le dashboard : la page, puis l'actif JavaScript qu'elle reference. Sans le
# stage `web`, //go:embed static n'embarquerait rien et cette page serait vide.
HTML=$(curl -fsS --noproxy '*' "http://$API/dashboard/")
grep -q '<div id="root"' <<<"$HTML" || ko "/dashboard/ ne rend pas l'application (actifs non embarques ?)"
# Le chemin est RELATIF (`./assets/index-<hash>.js`) : l'amont construit avec
# VITE_APP_BASE_URL vide, donc la page marche sous n'importe quel prefixe.
ASSET=$(grep -m1 -oE 'assets/[A-Za-z0-9._-]+\.js' <<<"$HTML")
[ -n "$ASSET" ] || ko "aucun actif JavaScript reference par le dashboard"
TAILLE=$(curl -fsS --noproxy '*' -o /dev/null -w '%{size_download}' "http://$API/dashboard/${ASSET}")
[ "$TAILLE" -gt 100000 ] || ko "l'actif $ASSET ne pese que $TAILLE octets"
ok "dashboard embarque ($ASSET, $TAILLE octets)"

[ "$(curl -fsS --noproxy '*' -H 'Host: proxy.test' -o /dev/null -w '%{http_code}' "http://$WEB/ping")" = 200 ] \
  || ko "routage par le provider fichier"
[ "$(curl -sS --noproxy '*' -H 'Host: inconnu.test' -o /dev/null -w '%{http_code}' "http://$WEB/ping")" = 404 ] \
  || ko "routage : un hote inconnu devrait recevoir 404"
ok "routage entryPoint -> routeur -> service (et 404 hors regle)"

[ "$(curl -fsS --noproxy '*' -k -H 'Host: proxy.test' --resolve "proxy.test:${TLS##*:}:127.0.0.1" \
      -o /dev/null -w '%{http_code}' "https://proxy.test:${TLS##*:}/ping")" = 200 ] || ko "terminaison TLS"
SUJET=$(echo | openssl s_client -connect "$TLS" -servername proxy.test 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null || true)
grep -q "test.local" <<<"$SUJET" || ko "le certificat servi n'est pas celui fourni : $SUJET"
ok "terminaison TLS avec le certificat fourni ($SUJET)"

# Zero shell, zero bibliotheque partagee : le binaire est statique, donc une
# image sans chargeur ne peut rien charger -- et check-image-closure.sh SAUTE
# une telle image (vert, non examinee). C'est donc ici qu'on le prouve.
for sh in /bin/sh /bin/ash /bin/busybox /usr/bin/env; do
  if docker run --rm --entrypoint "$sh" "$IMAGE" -c true >/dev/null 2>&1; then
    ko "$sh existe dans l'image"
  fi
done
ok "aucun shell (sh, ash, busybox, env)"

CID=$(docker create "$IMAGE")
LIBS=$(docker export "$CID" | tar -t 2>/dev/null | grep -cE '(^|/)(lib|ld-).*\.so' || true)
docker rm -f "$CID" >/dev/null
[ "$LIBS" = 0 ] || ko "$LIBS bibliotheque(s) partagee(s) dans une image qui ne devrait en avoir aucune"
ok "aucune bibliotheque partagee embarquee"

[ "$(docker inspect -f '{{.Config.User}}' "$IMAGE")" = "65532:65532" ] || ko "l'image ne tourne pas en 65532"
ok "uid/gid 65532 (celui du securityContext de la cible)"

# Une configuration cassee ne doit PAS demarrer.
mkdir -p "$TMP/ko"
printf 'entryPoints:\n  web:\n    address: ":8000"\nproviders:\n  inconnu: {}\n' > "$TMP/ko/traefik.yml"
chmod 644 "$TMP/ko/traefik.yml"; chmod 755 "$TMP/ko"
run "$NOM-ko" "$TMP/ko"
for _ in $(seq 1 15); do
  [ "$(docker inspect -f '{{.State.Status}}' "$NOM-ko")" = exited ] && break
  sleep 1
done
ETAT=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$NOM-ko")
[ "$ETAT" = "exited 0" ] && ko "une configuration cassee a demarre puis rendu 0" "$NOM-ko"
case "$ETAT" in exited\ *) ;; *) ko "une configuration cassee tourne toujours ($ETAT)" "$NOM-ko" ;; esac
ok "configuration cassee refusee au demarrage ($ETAT)"

# Plugin demande, mais /plugins-storage non inscriptible (rootfs en lecture
# seule sans volume) : l'init doit le DIRE, sinon le diagnostic se fait dans
# une pile Go au bout de plusieurs redemarrages.
docker run -d --name "$NOM-plug" \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true --user 65532:65532 \
  --tmpfs /tmp:mode=1777 \
  -v "$TMP:/etc/traefik:ro" \
  "$IMAGE" traefik --configFile=/etc/traefik/traefik.yml \
  --experimental.plugins.demo.moduleName=github.com/exemple/demo \
  --experimental.plugins.demo.version=v0.0.1 >/dev/null
for _ in $(seq 1 10); do
  journal_contient "$NOM-plug" 'plugins-storage' && break
  sleep 1
done
journal_contient "$NOM-plug" "WARNING: /plugins-storage n'est pas inscriptible" \
  || ko "l'init n'avertit pas sur /plugins-storage non inscriptible" "$NOM-plug"
ok "avertissement clair quand /plugins-storage n'est pas inscriptible"

echo "== tous les tests passent"
