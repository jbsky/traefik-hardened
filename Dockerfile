# syntax=docker/dockerfile:1
# =====================================================================
#  traefik-hardened -- Traefik FROM scratch
#  fetch -> web -> builder -> gobuilder -> prep -> prep-clean -> scratch
#
#  Traefik (le service expose) est compile depuis l'archive source du tag,
#  verifiee par son sha256 (l'amont ne publie ni signature ni somme pour
#  cette archive : seules les binaires sont dans checksums.txt).
#
#  Le DASHBOARD est RECONSTRUIT depuis ses sources TypeScript. L'archive
#  « source » de l'amont embarque un webui/static DEJA construit
#  (static/assets/index-*.js) : un artefact opaque sorti de la chaine de
#  release. Le stage `fetch` le supprime, `web` le refabrique avec vite, et
#  `go build` echouerait si ce stage ne rendait rien (//go:embed static).
#
#  Aucune version n'est ecrite ici : versions.json est la seule source
#  (scripts/versions-build-args.py, verifie au job lint).
# =====================================================================
ARG TRAEFIK_VERSION
ARG TRAEFIK_SHA256
# Pas d'ARG ALPINE_VERSION : les FROM epinglent tag ET digest en litteral, et
# scripts/versions-build-args.py --check compare ce tag a .alpine.

# ---------------------------------------------------------------------
#  fetch : archive source verifiee, dashboard prefabrique jete
# ---------------------------------------------------------------------
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS fetch
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG TRAEFIK_VERSION
ARG TRAEFIK_SHA256
# Echouer tout de suite, avec la marche a suivre, plutot que construire a vide.
RUN test -n "${TRAEFIK_VERSION}" -a -n "${TRAEFIK_SHA256}" \
    || { echo "build-args requis depuis versions.json : make build, ou docker build \$(scripts/versions-build-args.py --docker) ." >&2; exit 1; }

# Derriere un proxy qui dechiffre le TLS : CA en secret BuildKit, jamais en
# couche. Ce stage n'est pas publie.
RUN --mount=type=secret,id=ca-certs,target=/tmp/ca-bundle.crt,required=false \
    if [ -f /tmp/ca-bundle.crt ]; then \
      cat /tmp/ca-bundle.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi

RUN apk upgrade --no-cache \
 && apk add --no-cache curl

# Telechargement et verification dans le MEME RUN ; sha256 compare depuis un
# fichier, jamais par un pipe (qui reussit sur un flux vide).
WORKDIR /src
RUN curl -fsSL "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik-v${TRAEFIK_VERSION}.src.tar.gz" -o traefik.tar.gz \
 && printf '%s  traefik.tar.gz\n' "${TRAEFIK_SHA256}" > traefik.sha256 \
 && sha256sum -c traefik.sha256 \
 && mkdir traefik \
 && tar -xzf traefik.tar.gz -C traefik \
 && rm traefik.tar.gz traefik.sha256

# Le dashboard prefabrique de l'amont s'en va ici : rien, plus loin, ne peut
# le reintroduire par inadvertance. webui/public/ (icones, robots.txt,
# manifest) reste : vite le recopie dans static/ a la construction.
RUN test -s traefik/webui/static/index.html \
 && test -d traefik/webui/src \
 && rm -rf traefik/webui/static

# ---------------------------------------------------------------------
#  plugin : source du bouncer CrowdSec, vendue dans l'image (localPlugins)
#
#  Charge jusqu'ici via experimental.plugins (catalogue distant) : Traefik
#  RETELECHARGE ce plugin a CHAQUE demarrage, meme une archive deja en cache
#  sous /plugins-storage ne l'evite pas (verifie le 2026-10-14,
#  bin/k3s-traefik-preflight-plugin.sh, --network none). Un redemarrage dont
#  le reseau n'est pas encore pret (reboot du noeud, proxy pas remonte)
#  desactive alors les plugins pour toute la vie du pod -- et le middleware
#  qui en depend casse TOUTE la chaine WAF (vecu en prod le 2026-11-04,
#  21 minutes, tous les sites en 404 : jbsky.fr, home.jbsky.fr, mail,
#  immich...).
#
#  experimental.localPlugins fait lire le code par Yaegi depuis le disque :
#  aucun reseau au demarrage. La source est verifiee ICI, au build, comme le
#  binaire Traefik lui-meme -- l'amont ne publie ni signature ni somme pour
#  cette archive non plus.
# ---------------------------------------------------------------------
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS plugin
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG CROWDSEC_BOUNCER_PLUGIN_VERSION
ARG CROWDSEC_BOUNCER_PLUGIN_SHA256
RUN test -n "${CROWDSEC_BOUNCER_PLUGIN_VERSION}" -a -n "${CROWDSEC_BOUNCER_PLUGIN_SHA256}" \
    || { echo "build-args requis depuis versions.json : make build, ou docker build \$(scripts/versions-build-args.py --docker) ." >&2; exit 1; }

RUN --mount=type=secret,id=ca-certs,target=/tmp/ca-bundle.crt,required=false \
    if [ -f /tmp/ca-bundle.crt ]; then \
      cat /tmp/ca-bundle.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi

RUN apk upgrade --no-cache \
 && apk add --no-cache curl

WORKDIR /src
RUN curl -fsSL "https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/archive/refs/tags/v${CROWDSEC_BOUNCER_PLUGIN_VERSION}.tar.gz" -o plugin.tar.gz \
 && printf '%s  plugin.tar.gz\n' "${CROWDSEC_BOUNCER_PLUGIN_SHA256}" > plugin.sha256 \
 && sha256sum -c plugin.sha256 \
 && mkdir -p src/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin \
 && tar -xzf plugin.tar.gz --strip-components=1 -C src/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin \
 && rm plugin.tar.gz plugin.sha256

# Yaegi n'INTERPRETE que le code : ni les tests, ni les exemples, ni
# l'outillage amont n'entrent dans l'image. `.traefik.yml` EST lu au
# demarrage (le manifeste du plugin) : sans lui Traefik refuse avec
# « failed to open the plugin manifest » -- prouve en rouge le 2026-11-04 sur
# l'image sans cette stage. `vendor/` reste : go.mod declare deux modules
# tiers (golang-ttl-map, simpleredis) que Yaegi resout depuis ce
# repertoire, jamais depuis le reseau.
WORKDIR /src/src/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin
RUN rm -rf examples .github tests .assets docker-compose.yml docker-compose.local.yml \
      Makefile .golangci.yml .gitignore README.md acquis.yaml ban.html captcha.html bouncer_test.go \
 && find pkg -name '*_test.go' -delete \
 && test -s .traefik.yml \
 && test -s bouncer.go \
 && test -d vendor/github.com/maxlerebourg/simpleredis

# ---------------------------------------------------------------------
#  web : dashboard construit depuis les sources du tag
# ---------------------------------------------------------------------
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS web
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
RUN --mount=type=secret,id=ca-certs,target=/tmp/ca-bundle.crt,required=false \
    if [ -f /tmp/ca-bundle.crt ]; then \
      cat /tmp/ca-bundle.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi

RUN apk upgrade --no-cache \
 && apk add --no-cache nodejs npm

COPY --from=fetch /src/traefik /src/traefik
WORKDIR /src/traefik/webui

# Node lit son propre magasin d'autorites, pas /etc/ssl/certs : sans ca, yarn
# echoue sur « self-signed certificate » derriere le proxy SSL-bump.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
# Memes variables que l'amont (webui/buildx.Dockerfile) : le dashboard est
# servi sous /dashboard/ avec une API relative.
ENV VITE_APP_BASE_URL="" \
    VITE_APP_BASE_API_URL="/api"

# yarn 4 s'installe par npm, a la version que l'AMONT epingle dans son champ
# `packageManager` -- lue ici, jamais recopiee : une version de plus dans ce
# Dockerfile serait une seconde source. Le paquet npm est `@yarnpkg/cli-dist`
# (le paquet `yarn` s'arrete a la 1.22), c'est celui que corepack telecharge.
#
# Pourquoi pas corepack, que l'amont utilise : mesure faite ici, il ouvre une
# connexion DIRECTE (repo.yarnpkg.com, puis le registre npm) et ne lit aucune
# variable de proxy -- ECONNREFUSED sur un reseau qui n'autorise que son
# proxy, la ou npm et yarn, eux, la lisent. Contrepartie assumee : le sha512
# du champ `packageManager` n'est plus verifie ; l'integrite vient du registre
# npm. `.yarnrc.yml` de l'amont porte deja `enableScripts: false`, donc aucun
# script d'installation ne tourne.
RUN pm="$(node -p "require('./package.json').packageManager")" \
 && case "${pm}" in yarn@*) ;; *) echo "packageManager inattendu : ${pm}" >&2; exit 1 ;; esac \
 && ver="${pm#yarn@}" && ver="${ver%%+*}" \
 && echo "yarn epingle par l'amont : ${ver}" \
 && npm install -g --no-audit --no-fund "@yarnpkg/cli-dist@${ver}" \
 && pose="$(yarn --version)" \
 && test "${pose}" = "${ver}"

# `yarn build` (vite) et non `yarn build:prod` : cette derniere enchaine
# vitest + tsc + eslint, qui sont les portes de qualite de l'AMONT, pas de
# cette image -- elles n'ont rien a dire sur un tag deja publie.
#
# YARN_* : yarn 4 lit chaque cle de configuration dans une variable
# d'environnement YARN_<CLE>. Les variables de proxy du build (BuildKit les
# transmet telles quelles) ne lui parlent pas autrement.
RUN if [ -n "${HTTP_PROXY:-}" ]; then export YARN_HTTP_PROXY="${HTTP_PROXY}"; fi \
 && if [ -n "${HTTPS_PROXY:-}" ]; then export YARN_HTTPS_PROXY="${HTTPS_PROXY}"; fi \
 && yarn install --immutable \
 && yarn build \
 && test -s static/index.html \
 && test -n "$(find static/assets -name '*.js' -print -quit)" \
 && test -s static/robots.txt

# ---------------------------------------------------------------------
#  builder : Traefik compile depuis les sources
#
#  Pas de `-buildmode=pie` : mesure faite sur golang:1.27-alpine, meme avec
#  `-linkmode=internal`, Go produit pour linux/amd64 un PIE AVEC interpreteur
#  (/lib/ld-musl-x86_64.so.1). Il faudrait embarquer le chargeur et la libc
#  dans une image qui n'a aujourd'hui AUCUNE bibliotheque -- un plus mauvais
#  echange que l'ASLR gagnee. Le binaire reste statique, comme chez l'amont.
# ---------------------------------------------------------------------
FROM golang:1.27-alpine@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS builder
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG TRAEFIK_VERSION
RUN test -n "${TRAEFIK_VERSION}" \
    || { echo "TRAEFIK_VERSION est requis : make build, ou docker build \$(scripts/versions-build-args.py --docker) ." >&2; exit 1; }

RUN --mount=type=secret,id=ca-certs,target=/tmp/ca-bundle.crt,required=false \
    if [ -f /tmp/ca-bundle.crt ]; then \
      cat /tmp/ca-bundle.crt >> /etc/ssl/certs/ca-certificates.crt; \
    fi

COPY --from=fetch /src/traefik /src/traefik
COPY --from=web /src/traefik/webui/static /src/traefik/webui/static
WORKDIR /src/traefik

# GOTOOLCHAIN=local : la chaine d'outils est celle de l'image, jamais une
# autre telechargee a la volee parce que go.mod demande plus recent.
# GOFLAGS=-mod=readonly : go.mod/go.sum du tag font loi, l'integrite des
# modules vient de go.sum et de sum.golang.org.
ENV CGO_ENABLED=0 \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=readonly

# Overrides de securite (go-overrides.json, cf. SECURITY.md) : un module Go
# VENDU par l'amont (le source de Traefik qu'on compile, pas notre init.go)
# n'est touche ni par le digest golang ni par une reconstruction simple --
# scripts/go-cve-autofix.js (workflow go-cve-watch.yml, local a ce depot) y
# repond en forcant ici la version corrigee. `go get` passe par go.sum et
# sum.golang.org (meme garantie d'integrite que le reste du module) ;
# -mod=mod seulement pour cette commande, le reste du build reste readonly.
COPY go-overrides.json scripts/go-overrides-apply.sh /tmp/overrides/
RUN apk add --no-cache jq \
 && GOFLAGS=-mod=mod /tmp/overrides/go-overrides-apply.sh apply /tmp/overrides/go-overrides.json

# Codename non fourni : l'amont le passe par une variable de sa chaine de
# release, absente des sources. Le defaut du code (« cheddar ») s'applique,
# comme dans le paquet Alpine.
RUN builddate="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
 && go build -trimpath \
      -ldflags "-s -w \
        -X github.com/traefik/traefik/v3/pkg/version.Version=${TRAEFIK_VERSION} \
        -X github.com/traefik/traefik/v3/pkg/version.BuildDate=${builddate}" \
      -o /out/traefik ./cmd/traefik \
 && echo "traefik=${TRAEFIK_VERSION}" > /out/image-versions

# Le binaire doit etre STATIQUE : dans une image sans chargeur, un ELF
# dynamique ne demarre pas -- et `check-image-closure.sh` SAUTE une image sans
# chargeur musl (vert, non examinee). C'est donc ici que ca se prouve.
RUN apk add --no-cache file \
 && desc="$(file -b /out/traefik)" \
 && echo "${desc}" \
 && case "${desc}" in \
      *"dynamically linked"*|*interpreter*) \
        echo "le binaire traefik est dynamique : son chargeur manquerait dans l'image finale" >&2; exit 1 ;; \
      *"statically linked"*) ;; \
      *) echo "type de binaire inattendu : ${desc}" >&2; exit 1 ;; \
    esac

# Le binaire est bien la version que l'image portera (assertion R2 au build ;
# la CI la refait sur l'image publiee).
# Sortie capturee AVANT le grep : avec `pipefail`, `| grep -q` sort a la
# premiere correspondance et l'ecrivain meurt de SIGPIPE (141) s'il ecrit
# encore -- echec aleatoire vecu sur haproxy-hardened (PR #2).
RUN sortie="$(/out/traefik version)" \
 && echo "${sortie}" \
 && echo "${sortie}" | grep -E "^Version:[[:space:]]+${TRAEFIK_VERSION}$" > /dev/null

# Preuve que chaque override a reellement atteint le binaire compile :
# `go version -m` lit exactement le meme buildinfo que Trivy (cf.
# go-cve-watch.yml), donc la verification la plus proche du defaut qu'une
# CVE Go corrige. /tmp/overrides n'est range qu'ici : verify en a besoin.
RUN /tmp/overrides/go-overrides-apply.sh verify /tmp/overrides/go-overrides.json /out/traefik \
 && rm -rf /tmp/overrides

# ---------------------------------------------------------------------
#  gobuilder : init statique (entrypoint, healthcheck, setup-dirs)
# ---------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@sha256:fa3d596898d9f126af7c01d14ee7597bab3f39cccf392ef36b69fe77cd681f18 AS gobuilder
ARG TARGETOS
ARG TARGETARCH
WORKDIR /build
COPY go.mod init.go ./
RUN CGO_ENABLED=0 GOOS=${TARGETOS:-linux} GOARCH=${TARGETARCH} go build -ldflags='-s -w' -trimpath -o /init .

# ---------------------------------------------------------------------
#  prep : utilisateur, autorites, fuseaux -- et les assertions sur le binaire
#  Le gabarit build-push construit et scanne ce stage a part (Trivy, SBOM).
# ---------------------------------------------------------------------
FROM alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS prep
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
# Rien de plus que ce que l'image finale emporte : ce stage est celui que la
# CI scanne (Trivy, SBOM attestee), et chaque paquet de plus y ajoute des CVE
# a lire. Les assertions sur le binaire tournent dans `builder`, qui a deja ce
# qu'il faut pour les faire.
# apk upgrade d'abord : `apk add` ne met jamais a jour un paquet deja dans la
# base (libcrypto3, musl...).
RUN apk upgrade --no-cache \
 && apk add --no-cache ca-certificates tzdata tini-static

# 65532 : l'uid que la cible k3s impose dans son securityContext
# (runAsUser/runAsGroup/fsGroup). Le declarer ici fait que l'uid du conteneur
# a un nom, et que le test local eprouve l'uid de la production.
RUN addgroup -g 65532 -S traefik \
 && adduser -S -D -H -u 65532 -h /nonexistent -s /sbin/nologin -G traefik traefik

COPY --from=builder /out/traefik /usr/local/bin/traefik
COPY --from=builder /out/image-versions /etc/image-versions

FROM prep AS prep-clean
RUN rm -rf /lib/apk /lib/libapk* /var/cache/apk /etc/apk /sbin/apk

# ---------------------------------------------------------------------
#  image finale
# ---------------------------------------------------------------------
FROM scratch
LABEL org.opencontainers.image.title="traefik-hardened" \
      org.opencontainers.image.description="Traefik FROM scratch -- compiled from source, dashboard rebuilt from sources, non-root, zero shell" \
      org.opencontainers.image.vendor="jbsky" \
      org.opencontainers.image.licenses="MIT AND Apache-2.0" \
      org.opencontainers.image.source="https://github.com/jbsky/traefik-hardened" \
      security.hardening.tier="platine" \
      security.hardening.features="from-scratch,no-shared-libraries,go-init,tini-pid1,zero-shell,non-root,cosign-signed,sbom,slsa-provenance"

COPY --link --from=prep-clean /etc/passwd /etc/passwd
COPY --link --from=prep-clean /etc/group  /etc/group
COPY --link --from=prep-clean /usr/local/bin/traefik /usr/local/bin/traefik
COPY --link --from=prep-clean /etc/image-versions /etc/image-versions
COPY --link --from=prep-clean /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --link --from=prep-clean /usr/share/zoneinfo/ /usr/share/zoneinfo/
COPY --link --from=prep-clean /sbin/tini-static /sbin/tini
COPY --link --from=gobuilder /init /usr/local/bin/init
# Source du plugin CrowdSec (Yaegi, experimental.localPlugins) : lue en
# ./plugins-local/src/<moduleName> relatif au repertoire de travail, qui
# reste / (WORKDIR ci-dessous). Chemin confirme par l'erreur exacte de
# Traefik quand ce repertoire manque : « failed to open the plugin
# manifest plugins-local/src/.../.traefik.yml ».
COPY --link --from=plugin /src/src/ /plugins-local/src/

RUN ["/usr/local/bin/init", "--setup-dirs"]

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Aucune configuration statique n'est livree, volontairement : Traefik lit
# /etc/traefik/traefik.yml tout seul s'il existe, et la cible k3s le pilote
# entierement par des arguments. Un fichier embarque se melerait en silence a
# ces arguments (providers ou entryPoints en plus). La configuration d'essai
# vit dans conf/ et se monte au test.
WORKDIR /
USER 65532:65532
# web, websecure, traefik (dashboard/ping/api), metrics
EXPOSE 80 443 8080 9100
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["/usr/local/bin/init", "--healthcheck"]
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/init"]
CMD ["traefik"]
