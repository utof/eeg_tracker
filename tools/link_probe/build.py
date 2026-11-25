#!/usr/bin/env python3
"""Build the throw-away link probe: two keys, Gradle, signing (DECISIONS row 1020).

  build.py keys                       make three throw-away keystores in keys/ (never the project's key) and print fingerprints
  build.py gradle                     Gradle build of the three UNSIGNED apks -> build/unsigned-apks.tar (runs anywhere with a JDK,
                                      the Android SDK and a Gradle 9.3.1; --reader-sha256 defaults to keys/fingerprints.json)
  build.py sign --unsigned TAR --out DIR [--label SHA]
                                      zipalign + apksigner with the keys, write link-probe-{source,reader,reader-wrongkey}-SHA.apk
  build.py all --out DIR              keys + gradle + sign on this machine

Why three steps: Gradle is heavy, so it may run on a worker PC (which never sees the keys: only the reader's certificate SHA-256, public,
goes in as -PreaderSha256); signing is light and happens where the keys are.
  source.jks  signs the source app           reader.jks  signs the reader the source trusts
  wrong.jks   signs the wrong-key reader (another package id), which the source must refuse
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEYS = HERE / "keys"
PASS = "probekey"  # throw-away keys that sign two test apps: the password protects nothing
ALIAS = "probe"
UNSIGNED = {  # output name -> where Gradle writes the unsigned apk (glob under the module)
    "source": ("source", "release", "source-*-unsigned.apk"),
    "reader": ("reader", "normal/release", "reader-normal-*-unsigned.apk"),
    "reader-wrongkey": ("reader", "wrongkey/release", "reader-wrongkey-*-unsigned.apk"),
}
KEY_OF = {"source": "source", "reader": "reader", "reader-wrongkey": "wrong"}


def sdk() -> Path:
    return Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT") or Path.home() / "android-sdk")


def build_tool(name: str) -> str:
    dirs = sorted((sdk() / "build-tools").glob("*/"), key=lambda p: [int(x) for x in p.name.split(".") if x.isdigit()])
    for d in reversed(dirs):
        if (d / name).exists():
            return str(d / name)
    sys.exit(f"build.py: {name} not found under {sdk()}/build-tools")


def keytool() -> str:
    jh = os.environ.get("JAVA_HOME")
    if jh and (Path(jh) / "bin/keytool").exists():
        return str(Path(jh) / "bin/keytool")
    found = shutil.which("keytool")
    if not found:
        sys.exit("build.py: keytool not found (set JAVA_HOME)")
    return found


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    print("$", " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, check=True, **kw)


def cert_sha256(keystore: Path) -> str:
    pem = subprocess.run(
        [keytool(), "-exportcert", "-rfc", "-alias", ALIAS, "-keystore", str(keystore), "-storepass", PASS],
        check=True, capture_output=True, text=True,
    ).stdout
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()


def cmd_keys(_: argparse.Namespace) -> dict[str, str]:
    KEYS.mkdir(exist_ok=True)
    fp: dict[str, str] = {}
    for name in ("source", "reader", "wrong"):
        ks = KEYS / f"{name}.jks"
        if not ks.exists():
            run([keytool(), "-genkeypair", "-keystore", str(ks), "-storetype", "PKCS12", "-alias", ALIAS, "-keyalg", "RSA",
                 "-keysize", "2048", "-validity", "3650", "-storepass", PASS, "-keypass", PASS,
                 "-dname", f"CN=link probe {name}, O=throw-away"], stdout=subprocess.DEVNULL)
        fp[name] = cert_sha256(ks)
    (KEYS / "fingerprints.json").write_text(json.dumps(fp, indent=2) + "\n")
    print(f"keys in {KEYS} (git-ignored); certificate SHA-256: " + ", ".join(f"{k} {v[:16]}..." for k, v in fp.items()))
    if len(set(fp.values())) != 3:
        sys.exit("build.py: the three keys are not different")
    return fp


def find_gradle() -> str:
    if os.environ.get("GRADLE_BIN"):
        return os.environ["GRADLE_BIN"]
    home = Path(os.environ.get("GRADLE_USER_HOME") or Path.home() / ".gradle")
    for g in sorted(home.glob("wrapper/dists/gradle-9.3.1-all/*/gradle-9.3.1/bin/gradle")):
        return str(g)
    found = shutil.which("gradle")
    if found:
        return found
    sys.exit("build.py: no Gradle found (set GRADLE_BIN; the app's Gradle 9.3.1 is under GRADLE_USER_HOME/wrapper/dists)")


def cmd_gradle(a: argparse.Namespace) -> None:
    sha = a.reader_sha256
    if not sha:
        fpf = KEYS / "fingerprints.json"
        if not fpf.exists():
            sys.exit("build.py gradle: pass --reader-sha256 HEX (or run `build.py keys` first)")
        sha = json.loads(fpf.read_text())["reader"]
    run([find_gradle(), "--no-daemon", "-q", "-Pkotlin.compiler.execution.strategy=in-process", f"-PreaderSha256={sha}",
         ":source:assembleRelease", ":reader:assembleNormalRelease", ":reader:assembleWrongkeyRelease"], cwd=HERE)
    outdir = HERE / "build" / "unsigned"
    shutil.rmtree(outdir, ignore_errors=True)
    outdir.mkdir(parents=True)
    for name, (mod, sub, pat) in UNSIGNED.items():
        hits = sorted((HERE / mod / "build/outputs/apk" / sub).glob(pat)) or sorted((HERE / mod / "build/outputs/apk").glob(f"**/{pat}"))
        if not hits:
            sys.exit(f"build.py gradle: no unsigned apk for {name} (looked for {pat} under {mod}/build/outputs/apk)")
        shutil.copy(hits[0], outdir / f"{name}.apk")
    tar = HERE / "build" / "unsigned-apks.tar"
    with tarfile.open(tar, "w") as t:
        for f in sorted(outdir.glob("*.apk")):
            t.add(f, arcname=f.name)
    print(f"unsigned apks: {tar}")


def git_label() -> str:
    try:
        return subprocess.run(["git", "-C", str(HERE), "rev-parse", "--short", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
    except Exception:
        return "dev"


def apk_cert(apk: Path) -> str:
    out = subprocess.run([build_tool("apksigner"), "verify", "--print-certs", str(apk)], check=True, capture_output=True, text=True).stdout
    return next(line.split()[-1] for line in out.splitlines() if "certificate SHA-256 digest" in line)


def cmd_sign(a: argparse.Namespace) -> list[Path]:
    fp = json.loads((KEYS / "fingerprints.json").read_text())
    label = a.label or git_label()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=HERE / "build" if (HERE / "build").exists() else None) as tmp:
        tmpd = Path(tmp)
        src = Path(a.unsigned)
        if src.is_file():
            with tarfile.open(src) as t:
                t.extractall(tmpd / "in", filter="data")
            src = tmpd / "in"
        done: list[Path] = []
        for name in UNSIGNED:
            raw = src / f"{name}.apk"
            if not raw.exists():
                sys.exit(f"build.py sign: {raw} missing")
            aligned = tmpd / f"{name}-aligned.apk"
            run([build_tool("zipalign"), "-f", "4", str(raw), str(aligned)])
            dest = out / f"link-probe-{name}-{label}.apk"
            run([build_tool("apksigner"), "sign", "--ks", str(KEYS / f"{KEY_OF[name]}.jks"), "--ks-pass", f"pass:{PASS}",
                 "--ks-key-alias", ALIAS, "--key-pass", f"pass:{PASS}", "--min-sdk-version", "28", "--out", str(dest), str(aligned)])
            run([build_tool("apksigner"), "verify", str(dest)])
            got = apk_cert(dest)
            if got != fp[KEY_OF[name]]:
                sys.exit(f"build.py sign: {dest.name} has certificate {got}, expected {fp[KEY_OF[name]]}")
            done.append(dest)
    # the three jobs of the keys: the source pins the reader's certificate, and the wrong-key reader must differ from it
    certs = {p.name: apk_cert(p) for p in done}
    pinned_in_source = subprocess.run(["unzip", "-p", str(done[0]), "classes*.dex"], capture_output=True).stdout.count(fp["reader"].encode())
    if pinned_in_source < 1:
        sys.exit("build.py sign: the source apk does not contain the reader's certificate SHA-256 (built with another key?)")
    if certs[done[1].name] != fp["reader"] or certs[done[2].name] == fp["reader"]:
        sys.exit("build.py sign: the reader / wrong-key reader certificates are not as intended")
    for p in done:
        print(f"{p}  cert {certs[p.name][:16]}...  {p.stat().st_size} bytes")
    return done


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("keys")
    g = sub.add_parser("gradle")
    g.add_argument("--reader-sha256")
    s = sub.add_parser("sign")
    s.add_argument("--unsigned", required=True, help="unsigned-apks.tar or a folder with source.apk, reader.apk, reader-wrongkey.apk")
    s.add_argument("--out", required=True)
    s.add_argument("--label", help="goes into the file names (default: git short sha)")
    al = sub.add_parser("all")
    al.add_argument("--out", required=True)
    al.add_argument("--label")
    a = ap.parse_args()
    if a.cmd == "keys":
        cmd_keys(a)
    elif a.cmd == "gradle":
        cmd_gradle(a)
    elif a.cmd == "sign":
        cmd_sign(a)
    else:
        cmd_keys(a)
        cmd_gradle(argparse.Namespace(reader_sha256=None))
        cmd_sign(argparse.Namespace(unsigned=str(HERE / "build" / "unsigned-apks.tar"), out=a.out, label=a.label))


if __name__ == "__main__":
    main()
