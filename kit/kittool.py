#!/usr/bin/env python3
"""Railway DSC suite - Linux patch kit for CrisSigner / IREPSSigner.

The vendors ship these signers only as Windows installers (.msi). The Linux builds
used by the suite are those installers' Java programs plus a small set of changed
classes (WebSocket TLS handling, PKCS#11/token handling, a GTK look-and-feel stand-in).

  build  (maintainer, on a machine where the signers work):
         compares the working Linux folder with the vendor MSI and writes ONLY the
         changed/added entries plus a recipe.  No vendor file that is unchanged, and
         no key or certificate, goes into the kit.
  apply  (user): rebuilds the Linux folder from the user's own MSI + the kit, then
         verifies every jar entry against the recipe (sha256 per entry).

Requires: python3, cabextract.  Run with python3 -I.
"""
import argparse, hashlib, io, json, os, shutil, subprocess, sys, tempfile, urllib.request, zipfile

APPS = {
    "cris":  {"exe": "CrisSigner.exe",  "jar": "crissigner_app.jar"},
    "ireps": {"exe": "IREPSSigner.exe", "jar": "irepssigner_app.jar"},
}
# Open-source libraries, byte-identical to these Maven Central releases (verified).
MAVEN = {
    "io7.1.12.jar":       "https://repo1.maven.org/maven2/com/itextpdf/io/7.1.12/io-7.1.12.jar",
    "kernel7.1.12.jar":   "https://repo1.maven.org/maven2/com/itextpdf/kernel/7.1.12/kernel-7.1.12.jar",
    "layout7.1.12.jar":   "https://repo1.maven.org/maven2/com/itextpdf/layout/7.1.12/layout-7.1.12.jar",
    "jna5.14.0.jar":      "https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.14.0/jna-5.14.0.jar",
    "poi3.720101029.jar": "https://repo1.maven.org/maven2/org/apache/poi/poi/3.7/poi-3.7.jar",
    "slf4japi1.7.13.jar": "https://repo1.maven.org/maven2/org/slf4j/slf4j-api/1.7.13/slf4j-api-1.7.13.jar",
    "bcprovjdk18on1.78.1.jar": "https://repo1.maven.org/maven2/org/bouncycastle/bcprov-jdk18on/1.78.1/bcprov-jdk18on-1.78.1.jar",
}
# Oracle JRE parts the vendor copied into its installer; never redistributed by the kit.
STUBS = {"sunmscapi.jar": "sunmscapi-stub.jar"}     # Windows-only provider; Linux never calls it
OPTIONAL = {"plugin.jar"}                           # browser-plugin classes; unused by the signers
SKIP_ROOT = {"run_crissigner.sh", "run_irepssigner.sh", "install_certificates.sh", "signer.log"}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def file_sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def flat(name):                       # MSI cabinets store "jna-5.14.0.jar" as "jna5.14.0.jar"
    return name.replace("-", "")


def entries(zpath):
    """name -> bytes for every file entry (works on .exe launchers with an appended jar)."""
    with zipfile.ZipFile(zpath) as z:
        return {i.filename: z.read(i) for i in z.infolist() if not i.is_dir()}


def digest(ents):
    return sha("".join(f"{n} {sha(b)}\n" for n, b in sorted(ents.items())).encode())


def unpack_msi(msi, dest):
    os.makedirs(dest, exist_ok=True)
    r = subprocess.run(["cabextract", "-q", "-d", dest, msi], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if r.returncode != 0:
        sys.exit(f"cabextract failed on {msi}: {r.stderr.decode(errors='replace').strip()}")


def write_zip(path, ents):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        names = sorted(ents, key=lambda n: (n != "META-INF/MANIFEST.MF", n))
        for n in names:
            zi = zipfile.ZipInfo(n, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            z.writestr(zi, ents[n])


def overlay(base, new):
    changed = {n: b for n, b in new.items() if base.get(n) != b}
    removed = sorted(n for n in base if n not in new)
    return changed, removed


# ------------------------------------------------------------------ build ---
def cmd_build(a):
    app = APPS[a.app]
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    tmp = tempfile.mkdtemp()
    try:
        unpack_msi(a.msi, f"{tmp}/msi")
        aux = None
        if a.aux_msi:
            unpack_msi(a.aux_msi, f"{tmp}/aux")
            aux = f"{tmp}/aux"
        recipe = {"app": a.app, "msi_sha256": file_sha(a.msi), "msi_name": os.path.basename(a.msi),
                  "aux_msi_sha256": file_sha(a.aux_msi) if a.aux_msi else None,
                  "aux_msi_name": os.path.basename(a.aux_msi) if a.aux_msi else None,
                  "jars": {}, "files": {}, "links": {}}
        lin = os.path.abspath(a.linux_dir)

        def jar_recipe(rel, base_ents, new_ents, tag):
            ch, rm = overlay(base_ents, new_ents)
            entry = {"source": tag, "digest": digest(new_ents), "removed": rm}
            if ch:
                pz = f"{tag.split(':', 1)[1] if ':' in tag else rel}.overlay.zip"
                pz = pz.replace("/", "_")
                write_zip(f"{out}/{pz}", ch)
                entry["overlay"] = pz
            recipe["jars"][rel] = entry
            return len(ch), len(rm)

        # main program: the jar appended to the vendor's .exe launcher
        c, r = jar_recipe(app["jar"], entries(f"{tmp}/msi/{app['exe']}"), entries(f"{lin}/{app['jar']}"), "exe:" + app["exe"])
        print(f"{app['jar']}: {c} changed/added, {r} removed entries")

        for name in sorted(os.listdir(f"{lin}/lib")):
            p = f"{lin}/lib/{name}"
            rel = f"lib/{name}"
            if not name.endswith(".jar"):
                continue                      # backups etc.: Java's lib/* only loads *.jar
            if os.path.islink(p):
                recipe["links"][rel] = os.readlink(p)
                continue
            fl = flat(name)
            data = open(p, "rb").read()
            own, other = f"{tmp}/msi/{fl}", (f"{aux}/{fl}" if aux else None)
            if os.path.exists(own) and open(own, "rb").read() == data:
                recipe["files"][rel] = {"source": "msi:" + fl, "sha256": sha(data)}
            elif other and os.path.exists(other) and open(other, "rb").read() == data:
                src = {"source": "aux:" + fl, "sha256": sha(data)}
                if fl in MAVEN:
                    src["maven"] = MAVEN[fl]
                if fl in STUBS:
                    src["stub"] = STUBS[fl]
                if fl in OPTIONAL:
                    src["optional"] = True
                recipe["files"][rel] = src
            elif name in ("windows-laf-stub.jar", "windowslookandfell-stub.jar"):
                shutil.copy(p, f"{out}/{name}")
                recipe["files"][rel] = {"source": "kit:" + name, "sha256": sha(data)}
            elif os.path.exists(own) and name.endswith(".jar"):
                c, r = jar_recipe(rel, entries(own), entries(p), "msi:" + fl)
                print(f"{rel}: patched ({c} changed/added, {r} removed entries)")
            else:
                sys.exit(f"cannot place {rel}: not in the MSI and not a known library")

        for name in sorted(os.listdir(lin)):
            p = f"{lin}/{name}"
            if name in SKIP_ROOT or os.path.isdir(p) or name == app["jar"]:
                continue
            own = f"{tmp}/msi/{name}"
            if os.path.exists(own):
                recipe["files"][name] = {"source": "msi:" + name, "sha256": file_sha(own)}   # vendor's copy
            # anything else (helper html pages, logs) is not needed to run
        with open(f"{out}/recipe.json", "w") as f:
            json.dump(recipe, f, indent=1, sort_keys=True)
        print(f"kit written to {out}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ------------------------------------------------------------------ apply ---
_FETCHED = {}


def fetch(url, want):
    if url in _FETCHED:
        return _FETCHED[url]
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    if sha(data) != want:
        sys.exit(f"download from {url} failed its checksum")
    _FETCHED[url] = data
    return data


def cmd_apply(a):
    kit = os.path.abspath(a.kit)
    rec = json.load(open(f"{kit}/recipe.json"))
    if file_sha(a.msi) != rec["msi_sha256"]:
        sys.exit(f"{a.msi} is not the vendor installer this kit was made for "
                 f"({rec['msi_name']}, sha256 {rec['msi_sha256'][:16]}...)")
    tmp = tempfile.mkdtemp()
    dest = os.path.abspath(a.dest)
    stage = dest + ".rdsc-new"
    try:
        unpack_msi(a.msi, f"{tmp}/msi")
        aux = None
        if a.aux_msi and rec.get("aux_msi_sha256") and file_sha(a.aux_msi) == rec["aux_msi_sha256"]:
            unpack_msi(a.aux_msi, f"{tmp}/aux")
            aux = f"{tmp}/aux"
        shutil.rmtree(stage, ignore_errors=True)
        os.makedirs(f"{stage}/lib")
        stubs = os.path.join(os.path.dirname(kit), "stubs")

        for rel, j in rec["jars"].items():
            kind, name = j["source"].split(":", 1)
            ents = entries(f"{tmp}/msi/{name}")
            for n in j["removed"]:
                ents.pop(n, None)
            if j.get("overlay"):
                ents.update(entries(f"{kit}/{j['overlay']}"))
            if digest(ents) != j["digest"]:
                sys.exit(f"rebuilt {rel} does not match the recipe - kit and installer do not belong together")
            write_zip(f"{stage}/{rel}", ents)

        missing = []
        for rel, f in rec["files"].items():
            kind, name = f["source"].split(":", 1)
            data = None
            if kind == "msi":
                data = open(f"{tmp}/msi/{name}", "rb").read()
            elif kind == "kit":
                data = open(f"{kit}/{name}", "rb").read()
            elif kind == "aux":
                if aux and os.path.exists(f"{aux}/{name}"):
                    data = open(f"{aux}/{name}", "rb").read()
                elif f.get("maven") and not a.offline:
                    if f["maven"] not in _FETCHED:
                        print(f"  downloading {os.path.basename(f['maven'])} from Maven Central")
                    data = fetch(f["maven"], f["sha256"])
                elif f.get("stub"):
                    shutil.copy(f"{stubs}/{f['stub']}", f"{stage}/{rel}")
                    print(f"  {rel}: using the suite's stub (the vendor copy is an Oracle JRE part)")
                    continue
                elif f.get("optional"):
                    continue
                else:
                    missing.append(rel)
                    continue
            if sha(data) != f["sha256"]:
                sys.exit(f"{rel}: checksum mismatch")
            with open(f"{stage}/{rel}", "wb") as o:
                o.write(data)
        if missing:
            sys.exit("missing (keep " + (rec.get("aux_msi_name") or "the other installer") +
                     " in ~/Downloads, or allow downloads): " + ", ".join(missing))
        for rel, target in rec["links"].items():
            lp = f"{stage}/{rel}"
            if os.path.exists(f"{stage}/lib/{target}"):
                os.symlink(target, lp)
        if os.path.exists(dest):
            os.rename(dest, f"{dest}.before-kit")
        os.rename(stage, dest)
        print(f"rebuilt {dest} from {os.path.basename(a.msi)} + kit (all jars verified)")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        shutil.rmtree(stage, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--app", choices=APPS, required=True)
    b.add_argument("--msi", required=True)
    b.add_argument("--aux-msi")
    b.add_argument("--linux-dir", required=True)
    b.add_argument("--out", required=True)
    p = sub.add_parser("apply")
    p.add_argument("--kit", required=True, help="kit/<app> directory")
    p.add_argument("--msi", required=True)
    p.add_argument("--aux-msi")
    p.add_argument("--dest", required=True)
    p.add_argument("--offline", action="store_true")
    a = ap.parse_args()
    (cmd_build if a.cmd == "build" else cmd_apply)(a)


if __name__ == "__main__":
    main()
