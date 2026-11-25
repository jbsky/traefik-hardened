#!/usr/bin/env node
// Tests purs de go-cve-autofix.js -- aucun reseau, aucun fichier. Lance par
// go-cve-watch.yml (job `test`) avant tout audit reel, et sur chaque PR qui
// touche l'un des deux fichiers.
"use strict";
const assert = require("node:assert");
const {
    decide, pickFix, cmp, major, parseSemver, groupByModule, groupByModuleGrype, fusionner,
    applyOverride, jetonSur,
} = require("./go-cve-autofix.js");

let n = 0;
function test(nom, fn) {
    n++;
    fn();
    console.log(`ok - ${nom}`);
}

test("parseSemver accepte v-prefixe et le strict X.Y.Z", () => {
    assert.strictEqual(parseSemver("v4.1.5"), "4.1.5");
    assert.strictEqual(parseSemver("4.1.6"), "4.1.6");
});

test("parseSemver rejette une pseudo-version Go", () => {
    assert.strictEqual(parseSemver("v0.0.0-20251216153728-9c8140b780d1"), null);
});

test("major lit le premier segment", () => {
    assert.strictEqual(major("4.1.5"), "4");
});

test("pickFix retient le plus bas correctif de la MEME majeure", () => {
    assert.strictEqual(pickFix("v4.1.5", "4.1.6"), "4.1.6");
    assert.strictEqual(pickFix("v4.1.5", "5.0.0, 4.1.6"), "4.1.6");
});

// Un avis qui couvre plusieurs branches liste un correctif PAR branche
// (GO-2026-6107 : 3.5.33, 3.6.14, 3.7.1) : le plus bas de la majeure est
// alors une RETROGRADATION sous l'installe -- jamais un correctif.
test("pickFix ignore les correctifs des branches inferieures a l'installe", () => {
    assert.strictEqual(pickFix("v3.7.0", "3.5.33, 3.6.14, 3.7.1"), "3.7.1");
    assert.strictEqual(pickFix("v3.7.0", "3.5.33, 3.6.14"), null);
});

test("pickFix refuse de sauter de majeure", () => {
    assert.strictEqual(pickFix("v4.1.5", "5.0.0"), null);
});

// Semantic Import Versioning : v0 et v1 partagent le MEME chemin d'import,
// seules les majeures >= 2 portent un suffixe /vN (issue #23,
// go.opentelemetry.io/otel/sdk/log v0.22.0 -> 1.47.0).
test("pickFix accepte v0 -> v1 (meme chemin d'import Go)", () => {
    assert.strictEqual(pickFix("v0.22.0", "1.47.0"), "1.47.0");
});

test("pickFix refuse toujours v1 -> v2 (chemin /v2 different)", () => {
    assert.strictEqual(pickFix("v1.9.0", "2.0.0"), null);
    assert.strictEqual(pickFix("v0.22.0", "2.0.0"), null);
});

test("pickFix refuse si l'installe n'est pas un semver strict", () => {
    assert.strictEqual(pickFix("v0.0.0-20251216153728-9c8140b780d1", "0.0.0-20260531000007-52dbd5ece63f"), null);
});

test("decide propose un override quand aucun n'existe encore", () => {
    const d = decide({ installedVersion: "v4.1.5", fixedVersionsCsv: "4.1.6", overrideVersion: null });
    assert.deepStrictEqual(d, { action: "override", version: "4.1.6" });
});

test("decide ne refait rien si l'override couvre deja le correctif", () => {
    const d = decide({ installedVersion: "v4.1.5", fixedVersionsCsv: "4.1.6", overrideVersion: "4.1.6" });
    assert.deepStrictEqual(d, { action: "none" });
});

test("decide remonte l'override si un correctif plus recent apparait", () => {
    const d = decide({ installedVersion: "v4.1.5", fixedVersionsCsv: "4.1.7", overrideVersion: "4.1.6" });
    assert.deepStrictEqual(d, { action: "override", version: "4.1.7" });
});

test("decide skip si aucun correctif de la meme forme n'existe", () => {
    const d = decide({
        installedVersion: "v0.0.0-20251216153728-9c8140b780d1",
        fixedVersionsCsv: "0.0.0-20260531000007-52dbd5ece63f",
        overrideVersion: null,
    });
    assert.deepStrictEqual(d, { action: "skip" });
});

test("groupByModule filtre par Target/Class/Type et ecarte stdlib et le module principal", () => {
    const rapport = {
        Results: [
            {
                Target: "usr/local/bin/traefik", Class: "lang-pkgs", Type: "gobinary",
                Vulnerabilities: [
                    { VulnerabilityID: "CVE-1", PkgName: "stdlib", InstalledVersion: "go1.27.3", FixedVersion: "go1.27.4" },
                    {
                        VulnerabilityID: "CVE-2", PkgName: "github.com/traefik/traefik/v3",
                        InstalledVersion: "v3.7.16", FixedVersion: "3.7.17",
                    },
                    {
                        VulnerabilityID: "CVE-3", PkgName: "github.com/go-jose/go-jose/v4",
                        InstalledVersion: "v4.1.5", FixedVersion: "4.1.6",
                    },
                ],
            },
            {
                Target: "usr/local/bin/init", Class: "lang-pkgs", Type: "gobinary",
                Vulnerabilities: [
                    { VulnerabilityID: "CVE-4", PkgName: "github.com/go-jose/go-jose/v4", InstalledVersion: "v4.1.5", FixedVersion: "4.1.6" },
                ],
            },
        ],
    };
    const g = groupByModule(rapport, "usr/local/bin/traefik", "github.com/traefik/traefik/v3");
    assert.deepStrictEqual(Object.keys(g), ["github.com/go-jose/go-jose/v4"]);
    assert.strictEqual(g["github.com/go-jose/go-jose/v4"].installedVersion, "v4.1.5");
    assert.deepStrictEqual(g["github.com/go-jose/go-jose/v4"].ids, ["CVE-3"]);
});

test("groupByModule regroupe plusieurs CVE sur le meme module", () => {
    const rapport = {
        Results: [
            {
                Target: "usr/local/bin/traefik", Class: "lang-pkgs", Type: "gobinary",
                Vulnerabilities: [
                    { VulnerabilityID: "CVE-A", PkgName: "example.com/mod", InstalledVersion: "v1.0.0", FixedVersion: "1.0.1" },
                    { VulnerabilityID: "CVE-B", PkgName: "example.com/mod", InstalledVersion: "v1.0.0", FixedVersion: "1.0.1" },
                ],
            },
        ],
    };
    const g = groupByModule(rapport, "usr/local/bin/traefik", "github.com/traefik/traefik/v3");
    assert.deepStrictEqual(g["example.com/mod"].ids, ["CVE-A", "CVE-B"]);
});

// Grype (security-audit) et Trivy (cette veille) ne lisent pas la meme base :
// le 2026-11-24, l'audit a vu GO-2026-6107 (go.etcd.io/etcd/client/pkg/v3
// v3.7.0, corrige en 3.7.1, issue #34) que Trivy ignore -- la veille disait
// "aucune CVE de module Go". Extrait reel de grype 0.110.0 -o json.
const GRYPE_ETCD = {
    matches: [
        {
            vulnerability: {
                id: "GO-2026-6107", severity: "High",
                fix: { versions: ["3.5.33", "3.6.14", "3.7.1"], state: "fixed" },
            },
            artifact: {
                name: "go.etcd.io/etcd/client/pkg/v3", version: "v3.7.0", type: "go-module",
                locations: [{ path: "/usr/local/bin/traefik" }],
            },
        },
        {
            vulnerability: { id: "GO-2026-0001", severity: "High", fix: { versions: ["1.27.9"], state: "fixed" } },
            artifact: { name: "stdlib", version: "go1.27.3", type: "go-module", locations: [{ path: "/usr/local/bin/traefik" }] },
        },
        {
            vulnerability: { id: "GO-2026-0002", severity: "High", fix: { versions: ["4.1.6"], state: "fixed" } },
            artifact: { name: "github.com/go-jose/go-jose/v4", version: "v4.1.5", type: "go-module", locations: [{ path: "/usr/local/bin/init" }] },
        },
        {
            vulnerability: { id: "GO-2026-0003", severity: "High", fix: { versions: [], state: "not-fixed" } },
            artifact: { name: "example.com/sans-fix", version: "v1.0.0", type: "go-module", locations: [{ path: "/usr/local/bin/traefik" }] },
        },
        {
            vulnerability: { id: "GO-2026-0004", severity: "Low", fix: { versions: ["1.0.1"], state: "fixed" } },
            artifact: { name: "example.com/faible", version: "v1.0.0", type: "go-module", locations: [{ path: "/usr/local/bin/traefik" }] },
        },
    ],
};

test("groupByModuleGrype lit le binaire traefik, hors stdlib, autre binaire, sans fix et Low", () => {
    const g = groupByModuleGrype(GRYPE_ETCD, "usr/local/bin/traefik", "github.com/traefik/traefik/v3");
    assert.deepStrictEqual(Object.keys(g), ["go.etcd.io/etcd/client/pkg/v3"]);
    assert.strictEqual(g["go.etcd.io/etcd/client/pkg/v3"].installedVersion, "v3.7.0");
    assert.deepStrictEqual(g["go.etcd.io/etcd/client/pkg/v3"].ids, ["GO-2026-6107"]);
});

test("GO-2026-6107 vu par Grype seul donne l'override 3.7.1", () => {
    const g = fusionner({}, groupByModuleGrype(GRYPE_ETCD, "usr/local/bin/traefik", "github.com/traefik/traefik/v3"));
    const e = g["go.etcd.io/etcd/client/pkg/v3"];
    const d = decide({ installedVersion: e.installedVersion, fixedVersionsCsv: e.fixedVersionsCsv, overrideVersion: null });
    assert.deepStrictEqual(d, { action: "override", version: "3.7.1" });
});

test("fusionner reunit les ids d'un module vu par les deux scanners", () => {
    const trivy = { "m": { installedVersion: "v1.0.0", fixedVersionsCsv: "1.0.1", ids: ["CVE-1"] } };
    const grype = { "m": { installedVersion: "v1.0.0", fixedVersionsCsv: "1.0.1, 1.0.2", ids: ["GO-1", "CVE-1"] },
                    "n": { installedVersion: "v2.0.0", fixedVersionsCsv: "2.0.1", ids: ["GO-2"] } };
    const f = fusionner(trivy, grype);
    assert.deepStrictEqual(f.m.ids, ["CVE-1", "GO-1"]);
    assert.deepStrictEqual(Object.keys(f).sort(), ["m", "n"]);
    assert.strictEqual(pickFix(f.m.installedVersion, f.m.fixedVersionsCsv), "1.0.1");
});

test("applyOverride trie les cles", () => {
    const r = applyOverride({ zed: { version: "1" } }, "abc", "2.0.0", ["CVE-X"]);
    assert.deepStrictEqual(Object.keys(r), ["abc", "zed"]);
    assert.deepStrictEqual(r.abc, { version: "2.0.0", fixes: ["CVE-X"] });
});

test("jetonSur accepte un chemin de module Go", () => {
    assert.strictEqual(jetonSur("github.com/go-jose/go-jose/v4"), "github.com/go-jose/go-jose/v4");
});

test("jetonSur refuse une injection shell", () => {
    assert.throws(() => jetonSur("pkg; rm -rf /"));
});

test("cmp compare bien X.Y.Z", () => {
    assert.ok(cmp("4.1.6", "4.1.5") > 0);
    assert.ok(cmp("4.1.5", "4.1.5") === 0);
});

console.log(`\n${n}/${n} ok`);
