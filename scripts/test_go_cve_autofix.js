#!/usr/bin/env node
// Tests purs de go-cve-autofix.js -- aucun reseau, aucun fichier. Lance par
// go-cve-watch.yml (job `test`) avant tout audit reel, et sur chaque PR qui
// touche l'un des deux fichiers.
"use strict";
const assert = require("node:assert");
const {
    decide, pickFix, cmp, major, parseSemver, groupByModule, applyOverride, jetonSur,
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

test("pickFix refuse de sauter de majeure", () => {
    assert.strictEqual(pickFix("v4.1.5", "5.0.0"), null);
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
