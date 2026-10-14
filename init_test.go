package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestEnv(t *testing.T) {
	const key = "TRAEFIK_INIT_TEST_VAR"

	if got := env(key, "default"); got != "default" {
		t.Errorf("env(%q, %q) = %q, want default value", key, "default", got)
	}

	t.Setenv(key, "custom")
	if got := env(key, "default"); got != "custom" {
		t.Errorf("env(%q, ...) = %q, want %q", key, got, "custom")
	}

	t.Setenv(key, "")
	if got := env(key, "default"); got != "default" {
		t.Errorf("env(%q, ...) with empty value = %q, want fallback %q", key, got, "default")
	}
}

func TestExists(t *testing.T) {
	dir := t.TempDir()
	present := filepath.Join(dir, "present")

	if exists(present) {
		t.Errorf("exists(%q) = true before file creation", present)
	}

	if err := os.WriteFile(present, nil, 0o644); err != nil {
		t.Fatalf("setup: %v", err)
	}
	if !exists(present) {
		t.Errorf("exists(%q) = false after file creation", present)
	}

	if exists(filepath.Join(dir, "absent")) {
		t.Errorf("exists() reported true for a path that was never created")
	}
}

func TestWriteOK(t *testing.T) {
	dir := t.TempDir()
	if !writeOK(dir) {
		t.Errorf("writeOK(%q) = false for a writable temp dir", dir)
	}

	if writeOK(filepath.Join(dir, "does-not-exist")) {
		t.Errorf("writeOK() = true for a non-existent directory")
	}
}

// Le chart Helm de Traefik ne fixe que `args:` -- une liste qui commence par
// « --entryPoints... » et qui REMPLACE le CMD. L'init doit remettre le nom du
// binaire devant, et ne rien toucher a une commande complete.
func TestCommandLine(t *testing.T) {
	// Le binaire Traefik n'existe pas dans l'environnement de test : on dit
	// ici ce qu'il repondrait (« version » oui, « /bin/sh » non).
	reel := isSubcommand
	t.Cleanup(func() { isSubcommand = reel })
	isSubcommand = func(name string) bool { return name == "version" || name == "healthcheck" }

	cases := []struct {
		name     string
		in, want []string
	}{
		{"sans argument", nil, []string{"traefik"}},
		{"args du chart", []string{"--entryPoints.web.address=:80", "--ping=true"},
			[]string{"traefik", "--entryPoints.web.address=:80", "--ping=true"}},
		{"commande complete", []string{"traefik", "version"}, []string{"traefik", "version"}},
		{"sous-commande", []string{"version"}, []string{"traefik", "version"}},
		{"chemin absolu", []string{"/usr/local/bin/init", "--healthcheck"},
			[]string{"/usr/local/bin/init", "--healthcheck"}},
		{"mot inconnu", []string{"rien-du-tout"}, []string{"rien-du-tout"}},
	}
	for _, c := range cases {
		if got := commandLine(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s : commandLine(%v) = %v, want %v", c.name, c.in, got, c.want)
		}
	}
}

// L'avertissement sur /plugins-storage ne doit sortir que si un plugin est
// reellement demande -- sinon il crie sur toutes les installations sans plugin.
func TestWantsPlugins(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want bool
	}{
		{"aucun", []string{"traefik", "--ping=true"}, false},
		{"plugin distant", []string{"traefik", "--experimental.plugins.bouncer.moduleName=github.com/x/y"}, true},
		{"plugin local", []string{"traefik", "--experimental.localPlugins.demo.moduleName=github.com/x/y"}, true},
	}
	for _, c := range cases {
		if got := wantsPlugins(c.args); got != c.want {
			t.Errorf("%s : wantsPlugins(%v) = %v, want %v", c.name, c.args, got, c.want)
		}
	}

	t.Setenv("TRAEFIK_EXPERIMENTAL_PLUGINS_BOUNCER_MODULENAME", "github.com/x/y")
	if !wantsPlugins([]string{"traefik"}) {
		t.Error("wantsPlugins() = false alors qu'une variable d'environnement declare un plugin")
	}
}
