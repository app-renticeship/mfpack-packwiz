#!/usr/bin/env python3
"""Scan for mod updates, and update single mods. Nothing here updates the whole pack at once.

  --scan                    check every mod (Modrinth and CurseForge) and write updates.json for the Pages console
  --only slug@version,...   update exactly these mods to exactly these versions (Modrinth version id or
                            CurseForge file id, as listed in updates.json), then rehash index.toml and pack.toml

Updates edit the .pw.toml in place (filename, url, hash, version id), so `pin`, `side` and comments survive.
New dependencies of an updated mod are NOT added: check the mod's page.

Channels for the scan (inclusive): release -> 'release' only; beta -> + beta; alpha -> + alpha.
The scan records the newest file for each channel; channel-overrides.json says which channel a mod is on by
default (keys: packwiz stem, Modrinth id or CurseForge project id).
"""
from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCAN_DIRS = ["mods", "resourcepacks", "shaderpacks"]
OVERRIDES = ROOT / "channel-overrides.json"
UPDATES = ROOT / "updates.json"
UA = {"User-Agent": "mfpack-packwiz-updater/2.0 (github.com/app-renticeship/mfpack-packwiz)"}
CHANNELS = ["release", "beta", "alpha"]
# Even if a file is marked "release", don't offer prerelease-looking names on the release channel.
UNSTABLE_NAME = re.compile(r"(?i)(alpha|beta|pre(?:-?release)?|\brc\d*\b|snapshot)")
CF_TYPE = {1: "release", 2: "beta", 3: "alpha"}
CF_NEOFORGE = 6
CF_KEY = base64.b64decode(
    "JDJhJDEwJHNBWVhqblU1N0EzSmpzcmJYM3JVdk92UWk2NHBLS3BnQ2VpbGc1TUM1UGNKL0RYTmlGWWxh"
).decode()


def http_json(url: str, headers: dict | None = None):
    for attempt in range(5):
        req = urllib.request.Request(url, headers={**UA, **(headers or {})})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429 or e.code >= 500:
                time.sleep(int(e.headers.get("Retry-After") or 0) or 2 ** attempt * 3)
                continue
            raise
    raise RuntimeError(f"gave up on {url}")


def cf(path: str):
    return http_json("https://api.curseforge.com/v1" + path, {"x-api-key": CF_KEY})


def mc_version() -> str:
    return re.search(r'^minecraft\s*=\s*"([^"]+)"', (ROOT / "pack.toml").read_text(encoding="utf-8"), re.M).group(1)


def load_overrides() -> dict[str, str]:
    if not OVERRIDES.is_file():
        return {}
    raw = json.loads(OVERRIDES.read_text(encoding="utf-8"))
    return {k: v for k, v in raw.items() if not str(k).startswith("_") and v in CHANNELS}


def get(text: str, key: str, block: str | None = None) -> str | None:
    if block:
        m = re.search(r"\[" + re.escape(block) + r"\]\s*\n(.*?)(?=\n\[|\Z)", text, re.S)
        if not m:
            return None
        text = m.group(1)
    m = re.search(r"^" + re.escape(key) + r"""\s*=\s*(?:["']([^"']*)["']|(\d+))""", text, re.M)
    return (m.group(1) if m.group(1) is not None else m.group(2)) if m else None


def put(text: str, key: str, value, block: str | None = None) -> str:
    """Replace key's value (keeping its quote style), inside [block] if given."""
    def sub(t: str) -> str:
        def rep(m):
            if isinstance(value, int):
                return f"{m.group(1)}{value}"
            q = m.group(2)[0] if m.group(2)[0] in "\"'" else '"'
            return f"{m.group(1)}{q}{value}{q}"
        new, n = re.subn(r"^(" + re.escape(key) + r"""\s*=\s*)("[^"]*"|'[^']*'|\d+)""", rep, t, count=1, flags=re.M)
        if not n:
            raise KeyError(key)
        return new
    if not block:
        return sub(text)
    m = re.search(r"(\[" + re.escape(block) + r"\]\s*\n)(.*?)(?=\n\[|\Z)", text, re.S)
    return text[: m.start(2)] + sub(m.group(2)) + text[m.end(2):]


def mods():
    for d in SCAN_DIRS:
        for path in sorted((ROOT / d).glob("*.pw.toml")):
            text = path.read_text(encoding="utf-8")
            yield {
                "slug": path.name[: -len(".pw.toml")],
                "path": path,
                "text": text,
                "name": get(text, "name") or path.stem,
                "filename": get(text, "filename") or "",
                "side": get(text, "side") or "both",
                "pinned": bool(re.search(r"^pin\s*=\s*true", text, re.M)),
                "mr_id": get(text, "mod-id", "update.modrinth"),
                "mr_ver": get(text, "version", "update.modrinth"),
                "cf_project": get(text, "project-id", "update.curseforge"),
                "cf_file": get(text, "file-id", "update.curseforge"),
            }


def channel_of(mod: dict, overrides: dict) -> str:
    for k in (mod["slug"], mod["mr_id"], mod["cf_project"], mod["name"]):
        if k and k in overrides:
            return overrides[k]
    return "release"


def newest_per_channel(files: list[dict]) -> dict:
    """files: [{id, version, type, date}] newest first -> {channel: file or None}."""
    out = {}
    for ch in CHANNELS:
        allowed = set(CHANNELS[: CHANNELS.index(ch) + 1])
        out[ch] = next((f for f in files if f["type"] in allowed
                        and not (ch == "release" and UNSTABLE_NAME.search(f["version"]))), None)
    return out


def scan_modrinth(mod: dict, mc: str):
    q = urllib.parse.urlencode({"loaders": json.dumps(["neoforge"]), "game_versions": json.dumps([mc])})
    vs = http_json(f"https://api.modrinth.com/v2/project/{mod['mr_id']}/version?{q}")
    files = [{"id": v["id"], "version": v["version_number"], "type": v["version_type"],
              "date": v["date_published"][:10]} for v in vs]
    files.sort(key=lambda f: f["date"], reverse=True)
    current = next((f for f in files if f["id"] == mod["mr_ver"]), None)
    return files, current


def scan_curseforge(mod: dict, mc: str):
    data = cf(f"/mods/{mod['cf_project']}/files?gameVersion={mc}&modLoaderType={CF_NEOFORGE}&pageSize=50")["data"]
    files = [{"id": str(f["id"]), "version": f["displayName"], "type": CF_TYPE.get(f["releaseType"], "alpha"),
              "date": f["fileDate"][:10]} for f in data]
    files.sort(key=lambda f: f["date"], reverse=True)
    current = next((f for f in files if f["id"] == mod["cf_file"]), None)
    return files, current


def scan() -> int:
    mc, overrides = mc_version(), load_overrides()
    rows = []
    for mod in mods():
        row = {"slug": mod["slug"], "name": mod["name"], "side": mod["side"], "pinned": mod["pinned"],
               "channel": channel_of(mod, overrides), "current": mod["filename"]}
        try:
            if mod["mr_id"]:
                row.update(source="modrinth", project=mod["mr_id"], current_id=mod["mr_ver"])
                files, cur = scan_modrinth(mod, mc)
            elif mod["cf_project"]:
                row.update(source="curseforge", project=mod["cf_project"], current_id=mod["cf_file"])
                files, cur = scan_curseforge(mod, mc)
            else:
                row["source"] = "manual"
                rows.append(row)
                continue
        except Exception as e:
            row["error"] = str(e)[:200]
            rows.append(row)
            continue
        if cur:
            row["current"] = cur["version"]
        row["current_date"] = cur["date"] if cur else None
        newest = newest_per_channel(files)
        # Only offer files newer than what we have (by date; ids aren't ordered across sources).
        floor = cur["date"] if cur else ""
        row["latest"] = {ch: (f if f and f["id"] != row["current_id"] and f["date"] >= floor else None)
                         for ch, f in newest.items()}
        rows.append(row)
        print(f"  {row['source']:10} {mod['slug']}: " +
              ", ".join(f"{ch}={f['version']}" for ch, f in row["latest"].items() if f), flush=True)
    UPDATES.write_text(json.dumps({
        "scanned_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "minecraft": mc, "mods": rows}, indent=1) + "\n", encoding="utf-8", newline="\n")
    print(f"Wrote updates.json ({len(rows)} mods)")
    return 0


def apply_modrinth(mod: dict, version_id: str) -> str:
    v = http_json(f"https://api.modrinth.com/v2/version/{version_id}")
    if v["project_id"] != mod["mr_id"]:
        raise ValueError(f"version {version_id} belongs to project {v['project_id']}, not {mod['mr_id']}")
    f = next((f for f in v["files"] if f.get("primary")), v["files"][0])
    t = mod["text"]
    t = put(t, "filename", f["filename"])
    t = put(t, "url", f["url"], "download")
    t = put(t, "hash-format", "sha512", "download")
    t = put(t, "hash", f["hashes"]["sha512"], "download")
    t = put(t, "version", version_id, "update.modrinth")
    if get(t, "x-prismlauncher-release-type"):
        t = put(t, "x-prismlauncher-release-type", v["version_type"])
    return t, v["version_number"]


def apply_curseforge(mod: dict, file_id: str) -> str:
    f = cf(f"/mods/{mod['cf_project']}/files/{file_id}")["data"]
    sha1 = next(h["value"] for h in f["hashes"] if h["algo"] == 1)
    t = mod["text"]
    t = put(t, "filename", f["fileName"])
    t = put(t, "hash-format", "sha1", "download")
    t = put(t, "hash", sha1, "download")
    t = put(t, "file-id", int(file_id), "update.curseforge")
    return t, f["displayName"]


def rehash(changed: list[Path]) -> None:
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    idx = (ROOT / "index.toml").read_text(encoding="utf-8")
    for p in changed:
        rel = p.relative_to(ROOT).as_posix()
        idx, n = re.subn(r'(file = "' + re.escape(rel) + r'"\nhash = ")[0-9a-f]+', lambda m: m.group(1) + sha(p), idx)
        if n != 1:
            raise RuntimeError(f"{rel} not found in index.toml")
    (ROOT / "index.toml").write_text(idx, encoding="utf-8", newline="\n")
    pack = (ROOT / "pack.toml").read_text(encoding="utf-8")
    pack = re.sub(r'(\[index\][^\[]*?hash = ")[0-9a-f]+', lambda m: m.group(1) + sha(ROOT / "index.toml"), pack)
    (ROOT / "pack.toml").write_text(pack, encoding="utf-8", newline="\n")


def update(spec: str) -> int:
    wanted = {}
    for item in filter(None, (s.strip() for s in spec.split(","))):
        slug, _, target = item.partition("@")
        if not target:
            sys.exit(f"'{item}': give slug@version (Modrinth version id or CurseForge file id) from updates.json")
        wanted[slug] = target
    if not wanted:
        sys.exit("No mods given. Whole-pack updates are disabled; pick mods on the Pages console.")
    by_slug = {m["slug"]: m for m in mods()}
    changed, done = [], []
    for slug, target in wanted.items():
        mod = by_slug.get(slug)
        if not mod:
            sys.exit(f"unknown mod {slug}")
        if mod["mr_id"]:
            text, ver = apply_modrinth(mod, target)
        elif mod["cf_project"]:
            text, ver = apply_curseforge(mod, target)
        else:
            sys.exit(f"{slug} has no Modrinth/CurseForge source; update it by hand")
        mod["path"].write_text(text, encoding="utf-8", newline="\n")
        changed.append(mod["path"])
        done.append(f"{mod['name']} {ver}")
        print(f"  {slug}: {mod['filename']} -> {ver}" + (" (pinned; pin kept)" if mod["pinned"] else ""))
    rehash(changed)
    Path(ROOT / ".update-summary").write_text("; ".join(done), encoding="utf-8")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--scan", action="store_true")
    ap.add_argument("--only", help="slug@version,... (from updates.json)")
    a = ap.parse_args()
    if a.only is not None:
        update(a.only)
    if a.scan:
        scan()
    if not a.scan and a.only is None:
        ap.error("use --scan and/or --only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
