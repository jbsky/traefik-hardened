# Security Audit Status

Le workflow hebdomadaire `security-audit.yml` (Trivy + Grype) scanne l'image
publiee, et `cve-watch.yml` relit chaque jour la SBOM du stage `prep` : une CVE
corrigeable ouvre une issue `cve`.

**Particularite de cette image** : le service est un binaire Go. Trivy et Grype
lisent le `buildinfo` d'un binaire Go et rapportent donc les CVE de ses
**modules**, ce qu'ils ne savent pas faire sur les images C du parc (ou ils ne
voient que des paquets). Un rapport rouge se traite par une montee de la version
amont -- jamais par une exception silencieuse, et jamais par `|| true`.

Aucune exception n'est suivie a ce jour. Toute exception future se documente ici
(CVE, module, pourquoi, quand elle se leve) avec une date d'expiration, avant
d'etre ajoutee a `.trivyignore` ou `.grype.yaml`.

**Overrides Go (`go-overrides.json`)** : une CVE sur un module VENDU par
l'amont (le source de Traefik qu'on compile, pas `init.go`) ne se corrige ni
par le digest `golang` ni par une reconstruction simple -- `go-cve-watch.yml`
(workflow local, pas un gabarit) force alors la version corrigee au build via
`go get` (integrite par `go.sum` et sum.golang.org), jamais par une exception
silencieuse. Piege a eviter : une montee MANUELLE de `versions.json` qui
corrige entre-temps le meme module rend l'override inutile sans le retirer --
`scripts/go-overrides-apply.sh` ne retrograde jamais (il l'ignore plutot que
de l'appliquer a l'envers), mais l'entree perimee doit quand meme etre retiree
de `go-overrides.json` dans le MEME commit que la montee de version, pour que
le fichier ne mente pas sur ce qui est encore necessaire.

Signaler une vulnerabilite de l'image : ouvrir une issue privee (security
advisory) sur ce depot. Une vulnerabilite de Traefik lui-meme se signale a
l'amont (https://github.com/traefik/traefik/security).
