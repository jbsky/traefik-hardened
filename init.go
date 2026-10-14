// Traefik hardened init -- remplace le /entrypoint.sh de l'image officielle et
// le healthcheck en shell. Binaire statique, aucune dependance au shell.
//
// Usage:
//
//	init --healthcheck      healthcheck Docker (exit 0/1)
//	init --setup-dirs       cree les repertoires runtime (au build, FROM scratch)
//	init [CMD [ARGS...]]    entrypoint : exec CMD, « traefik » par defaut
//
// Les arguments arrivent souvent SANS le nom du binaire : le chart Helm de
// Traefik ne fixe que `args:` (--entryPoints.web.address=:80, ...), qui
// remplace le CMD de l'image. Un premier argument qui commence par « - »
// recoit donc « traefik » devant, exactement comme le fait l'entrypoint.sh de
// l'amont.
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	traefikUID = 65532
	traefikGID = 65532
	traefikBin = "traefik"
	// Le chart k3s de la cible expose le point de controle sur l'entryPoint
	// « traefik » (:8080) avec --ping=true, et ses sondes interrogent /ping.
	defaultHealth = "http://127.0.0.1:8080/ping"
	// Traefik resout son stockage de plugins en RELATIF (« ./plugins-storage/ »,
	// cmd/traefik/plugins.go) : le repertoire de travail doit rester /.
	pluginDir = "/plugins-storage"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--healthcheck":
			os.Exit(healthcheck())
		case "--setup-dirs":
			if err := setupDirs(); err != nil {
				fmt.Fprintf(os.Stderr, "[init][ERROR] setup-dirs: %v\n", err)
				os.Exit(1)
			}
			return
		}
	}
	if err := entrypoint(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "[init][ERROR] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Setup directories -- appele au build, dans le stage FROM scratch.
// ---------------------------------------------------------------------------

func setupDirs() error {
	dirs := []struct {
		path string
		mode os.FileMode
		uid  int
		gid  int
	}{
		// Les trois volumes que la cible monte (emptyDir) : les creer avec le
		// bon proprietaire fait que l'image tourne AUSSI sans eux, et qu'un
		// montage sur un chemin absent ne masque rien d'inattendu.
		{"/tmp", 01777, 0, 0},
		{"/data", 0750, traefikUID, traefikGID},
		{pluginDir, 0750, traefikUID, traefikGID},
	}
	for _, d := range dirs {
		fmt.Printf("[init] mkdir %s (mode=%04o uid=%d gid=%d)\n", d.path, d.mode, d.uid, d.gid)
		if err := os.MkdirAll(d.path, d.mode); err != nil {
			return fmt.Errorf("mkdir %s: %w", d.path, err)
		}
		if err := os.Chmod(d.path, d.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", d.path, err)
		}
		if err := os.Chown(d.path, d.uid, d.gid); err != nil {
			return fmt.Errorf("chown %s: %w", d.path, err)
		}
	}
	fmt.Println("[init] setup-dirs complete")
	return nil
}

// ---------------------------------------------------------------------------
// Healthcheck : GET /ping, le protocole du service -- pas un connect TCP.
// La configuration doit l'activer (--ping=true, ou `ping: {}`) ; une autre
// URL se donne par TRAEFIK_HEALTH_URL.
//
// En Kubernetes ce healthcheck ne sert pas : le pod a ses propres sondes
// (livenessProbe/readinessProbe sur /ping). Il sert au test local et a
// Podman/Docker.
// ---------------------------------------------------------------------------

func healthcheck() int {
	url := env("TRAEFIK_HEALTH_URL", defaultHealth)
	client := &http.Client{
		Timeout: 5 * time.Second,
		Transport: &http.Transport{
			DialContext: (&net.Dialer{Timeout: 2 * time.Second}).DialContext,
			// Jamais le proxy de l'environnement : la cible en declare un
			// (HTTP_PROXY vers le proxy du homelab) et un healthcheck sur la
			// boucle locale ne doit pas en dependre.
			Proxy: nil,
		},
	}
	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[healthcheck] GET %s failed: %v\n", url, err)
		fmt.Fprintln(os.Stderr, "[healthcheck] l'entryPoint de controle est-il actif (--ping=true) ?")
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		fmt.Fprintf(os.Stderr, "[healthcheck] GET %s returned %d\n", url, resp.StatusCode)
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// Entrypoint : completer la ligne de commande, avertir sur ce qui echouerait
// plus tard, puis exec traefik.
// ---------------------------------------------------------------------------

func entrypoint(args []string) error {
	args = commandLine(args)

	// Un plugin (bouncer CrowdSec...) est DECOMPRESSE au demarrage sous
	// ./plugins-storage : en rootfs lecture seule sans volume dedie, Traefik
	// meurt en boucle. Le dire ici, en clair, plutot que dans une pile Go.
	if wantsPlugins(args) && exists(pluginDir) && !writeOK(pluginDir) {
		log("WARNING: %s n'est pas inscriptible par l'uid %d -- un plugin ne pourra pas s'y installer "+
			"(rootfs en lecture seule sans volume monte sur %s ?)", pluginDir, os.Getuid(), pluginDir)
	}
	if exists("/tmp") && !writeOK("/tmp") {
		log("WARNING: /tmp n'est pas inscriptible par l'uid %d (rootfs en lecture seule sans tmpfs ?)", os.Getuid())
	}

	log("Starting: %s", strings.Join(args, " "))
	return execCmd(args)
}

// commandLine complete les arguments bruts, comme l'entrypoint.sh de l'amont :
// le service seul sans argument, « traefik » devant un premier argument en
// « - » (le chart Helm ne fixe que `args:`, qui remplace le CMD), et
// « traefik » devant une de ses sous-commandes (`docker run <image> version`).
func commandLine(args []string) []string {
	if len(args) == 0 {
		return []string{traefikBin}
	}
	if strings.HasPrefix(args[0], "-") {
		return append([]string{traefikBin}, args...)
	}
	if args[0] == traefikBin || strings.Contains(args[0], "/") {
		return args
	}
	if isSubcommand(args[0]) {
		return append([]string{traefikBin}, args...)
	}
	return args
}

// isSubcommand demande au binaire si ce mot est une de ses sous-commandes --
// la methode de l'entrypoint.sh amont (`traefik "$1" --help`), qui ne depend
// d'aucune liste a tenir a jour. Variable pour que le test puisse la
// remplacer : l'image de test n'embarque pas Traefik.
var isSubcommand = func(name string) bool {
	cmd := exec.Command(traefikBin, name, "--help")
	cmd.Stdout = nil
	cmd.Stderr = nil
	return cmd.Run() == nil
}

// wantsPlugins dit si la ligne de commande declare un plugin (les variables
// d'environnement TRAEFIK_EXPERIMENTAL_PLUGINS_* comptent aussi).
func wantsPlugins(args []string) bool {
	for _, a := range args {
		if strings.Contains(strings.ToLower(a), "experimental.plugins") ||
			strings.Contains(strings.ToLower(a), "experimental.localplugins") {
			return true
		}
	}
	for _, e := range os.Environ() {
		if strings.HasPrefix(strings.ToUpper(e), "TRAEFIK_EXPERIMENTAL_PLUGINS") ||
			strings.HasPrefix(strings.ToUpper(e), "TRAEFIK_EXPERIMENTAL_LOCALPLUGINS") {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Helpers -- vocabulaire commun du parc : env, exists, writeOK
// ---------------------------------------------------------------------------

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// writeOK dit si un repertoire accepte reellement une ecriture. mkdir + chmod
// + chown peuvent tous reussir sur un point de montage en lecture seule :
// seule une ecriture le prouve.
func writeOK(dir string) bool {
	tmp, err := os.CreateTemp(dir, ".write-test-*")
	if err != nil {
		return false
	}
	name := tmp.Name()
	tmp.Close()
	os.Remove(name)
	return true
}

func execCmd(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("no command specified")
	}
	bin, err := exec.LookPath(args[0])
	if err != nil {
		return fmt.Errorf("command not found: %s", args[0])
	}
	return syscall.Exec(bin, args, os.Environ())
}

func log(format string, a ...any) {
	fmt.Printf("[init] "+format+"\n", a...)
}
