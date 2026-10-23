# Traefik Hardened

Traefik compile depuis les sources, dans une image `FROM scratch` : ni shell, ni
gestionnaire de paquets, ni OS -- et **aucune bibliotheque partagee**, le binaire
etant statique. Uniquement Traefik, son dashboard, les autorites de
certification, les fuseaux horaires, `tini` et un init Go statique.

| | Image officielle `traefik:3.x` | Cette image |
|---|---|---|
| Base | Alpine complete (busybox, ~1 600 fichiers) | `scratch` (le binaire, les autorites, les fuseaux, tini, l'init) |
| Utilisateur | `root` | `65532:65532` |
| Shell | `/bin/sh`, busybox | aucun |
| Bibliotheques partagees | musl, zlib... | aucune (binaire statique) |
| Dashboard | artefact de la chaine de release | **reconstruit** depuis les sources du tag |
| PID 1 | `entrypoint.sh` | `tini` statique |
| Provenance | -- | cosign (keyless), SBOM attestee, SLSA |

## Ce qui est construit, et depuis quoi

- **Traefik** : archive source du tag
  (`traefik-v<version>.src.tar.gz`), verifiee par son `sha256` epingle dans
  [`versions.json`](versions.json) -- l'amont ne publie de sommes que pour ses
  binaires, pas pour cette archive. Compilation `CGO_ENABLED=0`, `-trimpath`,
  `-ldflags "-s -w"`, `GOTOOLCHAIN=local`, `-mod=readonly` (l'integrite des
  modules vient de `go.sum` et de `sum.golang.org`).
- **Dashboard** : l'archive « source » de l'amont embarque un `webui/static`
  **deja construit**. Il est supprime, puis refabrique par `vite` depuis les
  sources TypeScript du meme tag, avec yarn a la version que l'amont epingle
  dans son champ `packageManager`. Sans ce stage, `//go:embed static`
  n'embarquerait rien.
- **Pas de `-buildmode=pie`** : mesure faite sur `golang:1.27-alpine`, meme avec
  `-linkmode=internal`, Go produit pour `linux/amd64` un PIE **avec
  interpreteur** (`/lib/ld-musl-x86_64.so.1`). Il faudrait embarquer un chargeur
  et une libc dans une image qui n'en a aucun : un plus mauvais echange que
  l'ASLR gagnee. Le build echoue si le binaire n'est pas statique.

## Hardening

- `FROM scratch`, utilisateur non-root `65532:65532`, aucune capacite requise.
- Rootfs en lecture seule : il suffit de monter `/tmp`, `/data` et
  `/plugins-storage` (tmpfs ou volume).
- Aucune configuration statique livree, volontairement : Traefik lit
  `/etc/traefik/traefik.yml` tout seul s'il existe, et un fichier embarque se
  melerait en silence aux arguments de la ligne de commande.
- L'init remplace l'`entrypoint.sh` de l'amont : il ajoute `traefik` devant une
  liste d'arguments qui commence par `-` (ce que fait un chart Helm, qui ne fixe
  que `args:`), et il **dit** pourquoi un plugin echouerait quand
  `/plugins-storage` n'est pas inscriptible, au lieu de laisser une pile Go.
- Chaque build verifie : binaire statique, version du binaire = version du tag,
  dashboard non vide, aucun shell, aucune bibliotheque partagee
  ([`scripts/test.sh`](scripts/test.sh)).

## Tags

Trois tags par image : `latest` (dernier build de `main`), la version amont
seule, et la version amont suffixee d'un **compteur de revision**. Les deux
premiers sont **reecrits en place** a chaque rebuild. **En production, epinglez
le tag qui porte le compteur.**

<!-- BEGIN:tags (genere par la CI -- ne pas editer a la main) -->
| Image | Version amont | Tag immuable a epingler |
|-------|---------------|-------------------------|
| `jbsky/traefik-hardened` | `3.7.14` | `3.7.14.3` |
<!-- END:tags -->

Le compteur compte les commits qui touchent les entrees de l'image
(`Dockerfile`, `init.go`, `go.mod`, `versions.json`) et repart a zero a chaque
nouvelle version de Traefik. `docker.io` et `ghcr.io` publient les memes tags
avec le meme digest.

## Usage

```bash
docker run -d --name traefik \
  --read-only --cap-drop ALL --security-opt no-new-privileges:true \
  --user 65532:65532 \
  --tmpfs /tmp:mode=1777 \
  --tmpfs /data:mode=0750,uid=65532,gid=65532 \
  --tmpfs /plugins-storage:mode=0750,uid=65532,gid=65532 \
  -v ./conf:/etc/traefik:ro \
  -p 80:80 -p 443:443 \
  jbsky/traefik-hardened:latest \
  traefik --configFile=/etc/traefik/traefik.yml
```

- **Ports privilegies** : aucune capacite n'est necessaire sous Kubernetes ni
  sous Docker, qui ouvrent les ports a partir de 0 pour les utilisateurs non
  privilegies (`net.ipv4.ip_unprivileged_port_start=0` dans le conteneur). Sous
  un moteur qui ne le fait pas, accorder `NET_BIND_SERVICE` au conteneur -- pas
  au binaire.
- **Arguments** : `--entryPoints.web.address=:80` & co. peuvent etre passes sans
  le nom du binaire, l'init ajoute `traefik` devant.
- **Healthcheck** : `GET http://127.0.0.1:8080/ping`, donc la configuration doit
  activer `ping` sur un entryPoint a `:8080` (ou pointer ailleurs avec
  `TRAEFIK_HEALTH_URL`). Sous Kubernetes, ce sont les sondes du pod qui comptent.
- **Plugins** (Yaegi) : ils sont telecharges puis decompresses sous
  `./plugins-storage` relatif au repertoire de travail, qui reste `/`. En
  lecture seule, monter un volume inscriptible sur `/plugins-storage`.
- **Fichiers montes** (certificats compris) : lisibles par l'uid `65532`
  (`chgrp 65532` + `chmod 640` sur les cles plutot qu'un `644`).

Exemple de configuration et de composition : [`conf/`](conf) et
[`docker-compose.yml`](docker-compose.yml) -- essais, pas un deploiement.

## Security & Verification

Image signee par [cosign](https://github.com/sigstore/cosign) (keyless OIDC).

```bash
cosign verify \
  --certificate-identity-regexp '^https://github.com/(jbsky/traefik-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/traefik-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/jbsky/traefik-hardened:latest

COSIGN_REPOSITORY=ghcr.io/jbsky/traefik-hardened \
  cosign verify \
  --certificate-identity-regexp '^https://github.com/(jbsky/traefik-hardened|jbsky/hardened-ci)/' \
  --certificate-github-workflow-repository jbsky/traefik-hardened \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/jbsky/traefik-hardened:latest
```

La chaine de CI vient de [jbsky/hardened-ci](https://github.com/jbsky/hardened-ci) :
lint, build, scan CVE du stage `prep`, tests sur le digest exact (manifeste
d'image, cloture, `scripts/test.sh`), signature, SBOM attestee, audit
hebdomadaire. La veille de versions (`version-watch.yml`) **signale** une
version amont plus recente sans la poser : ce que publie ce depot finit devant
tous les services, donc une montee se lit et se deploie a la main.

## License

Le contenu de ce depot -- Dockerfile, `init.go`, scripts et chaine CI -- est sous
**Apache-2.0**, voir [`LICENSE`](LICENSE). Copyright 2026 jbsky.

Traefik garde sa licence, **MIT**. `init.go` est un programme distinct, qui
execute Traefik sans etre lie a lui.
