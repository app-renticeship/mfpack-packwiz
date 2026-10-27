#!/usr/bin/env python3
"""Update packwiz mods with a release-channel policy.

Channels (inclusive):
  release → only Modrinth/CF 'release'
  beta    → release + beta
  alpha   → release + beta + alpha

Per-mod overrides: channel-overrides.json
  { "create-lanterns": "alpha", "COlSi5iR": "alpha" }

Usage:
  python scripts/update_channel.py --channel release
  python scripts/update_channel.py --channel beta
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODS = ROOT / "mods"
OVERRIDES = ROOT / "channel-overrides.json"
UA = {"User-Agent": "mfpack-packwiz-updater/1.0"}

CHANNEL_OK = {
    "release": {"release"},
    "beta": {"release", "beta"},
    "alpha": {"release", "beta", "alpha"},
}
# Even if Modrinth marks a file as "release", skip obvious prerelease names on the
# release channel (e.g. "2.0.0-Pre-Release-5").
UNSTABLE_NAME = re.compile(r"(?i)(alpha|beta|pre(?:-?release)?|\brc\d*\b|snapshot)")
# CurseForge releaseType: 1 release, 2 beta, 3 alpha
CF_TYPE = {1: "release", 2: "beta", 3: "alpha"}
CF_KEY = __import__("base64").b64decode(
    "JDJhJDEwJHNBWVhqblU1N0EzSmpzcmJYM3JVdk92UWk2NHBLS3BnQ2VpbGc1TUM1UGNKL0RYTmlGWWxh"
).decode()


def http_json(url: str, headers: dict | None = None):
    req = urllib.request.Request(url, headers={**UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def read_pack():
    text = (ROOT / "pack.toml").read_text(encoding="utf-8")
    mc = re.search(r'^minecraft\s*=\s*"([^"]+)"', text, re.M).group(1)
    return mc


def load_overrides() -> dict[str, str]:
    if not OVERRIDES.is_file():
        return {}
    raw = json.loads(OVERRIDES.read_text(encoding="utf-8"))
    return {k: v for k, v in raw.items() if not str(k).startswith("_") and isinstance(v, str)}


def parse_mod(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    name = (re.search(r'^name\s*=\s*["\']([^"\']+)["\']', text, re.M) or [None, path.stem])[1]
    filename = (re.search(r'^filename\s*=\s*["\']([^"\']+)["\']', text, re.M) or [None, ""])[1]
    mr = re.search(
        r"\[update\.modrinth\](.*?)\n(?=\[|\Z)", text, re.S
    ) or re.search(r"\[update\.modrinth\](.*)", text, re.S)
    cf = re.search(r"\[update\.curseforge\](.*?)\n(?=\[|\Z)", text, re.S) or re.search(
        r"\[update\.curseforge\](.*)", text, re.S
    )
    out = {"path": path, "name": name, "filename": filename, "text": text}
    if mr:
        block = mr.group(1)
        out["mr_id"] = (re.search(r'mod-id\s*=\s*["\']([^"\']+)["\']', block) or [None, None])[1]
        out["mr_ver"] = (re.search(r'version\s*=\s*["\']([^"\']+)["\']', block) or [None, None])[1]
    if cf:
        block = cf.group(1)
        out["cf_project"] = (re.search(r"project-id\s*=\s*(\d+)", block) or [None, None])[1]
        out["cf_file"] = (re.search(r"file-id\s*=\s*(\d+)", block) or [None, None])[1]
    return out


def effective_channel(mod: dict, default: str, overrides: dict) -> str:
    keys = [
        mod["path"].stem,
        mod.get("mr_id") or "",
        mod.get("cf_project") or "",
        mod.get("name") or "",
    ]
    for k in keys:
        if k and k in overrides:
            return overrides[k]
    return default


def channel_rank(ch: str) -> int:
    return {"release": 0, "beta": 1, "alpha": 2}.get(ch, 0)


def allowed_types(channel: str) -> set[str]:
    return CHANNEL_OK[channel]


def run_packwiz(*args: str) -> None:
    cmd = ["packwiz", *args, "-y"]
    print("+", " ".join(cmd), flush=True)
    subprocess.check_call(cmd, cwd=ROOT)


def set_cf_release_channel(path: Path, channel: str) -> None:
    text = path.read_text(encoding="utf-8")
    if "[update.curseforge]" not in text:
        return
    if re.search(r"release-channel\s*=", text):
        text = re.sub(
            r'release-channel\s*=\s*["\'][^"\']*["\']',
            f'release-channel = "{channel}"',
            text,
        )
    else:
        text = re.sub(
            r"(\[update\.curseforge\])",
            rf'\1\nrelease-channel = "{channel}"',
            text,
            count=1,
        )
    path.write_text(text, encoding="utf-8")


def update_modrinth(mod: dict, mc: str, channel: str) -> bool:
    mid = mod.get("mr_id")
    if not mid:
        return False
    loaders = urllib.parse.quote(json.dumps(["neoforge"]))
    games = urllib.parse.quote(json.dumps([mc]))
    url = f"https://api.modrinth.com/v2/project/{mid}/version?loaders={loaders}&game_versions={games}"
    try:
        versions = http_json(url)
    except Exception as e:
        print(f"  skip {mod['name']}: {e}")
        return False
    allowed = allowed_types(channel)
    candidates = []
    for v in versions:
        if v.get("version_type") not in allowed:
            continue
        # On release channel, also reject prerelease-looking version numbers
        if channel == "release" and UNSTABLE_NAME.search(v.get("version_number") or ""):
            continue
        candidates.append(v)
    if not candidates:
        print(f"  {mod['name']}: no {channel}-compatible version on Modrinth")
        return False
    best = candidates[0]
    if best["id"] == mod.get("mr_ver"):
        return False
    print(
        f"  MR {mod['name']}: {mod.get('mr_ver')} -> {best['id']} "
        f"({best.get('version_number')} / {best.get('version_type')})"
    )
    # Prefer version page install so packwiz rewrites metadata
    ver_url = f"https://modrinth.com/mod/{mid}/version/{best['id']}"
    try:
        run_packwiz("modrinth", "add", ver_url)
    except subprocess.CalledProcessError:
        # fallback: project slug install may not pin version — skip
        print(f"  FAILED install {mod['name']}")
        return False
    return True


def update_curseforge(mod: dict, mc: str, channel: str) -> bool:
    pid = mod.get("cf_project")
    if not pid:
        return False
    set_cf_release_channel(mod["path"], channel)
    # Use packwiz update by metadata file stem
    stem = mod["path"].stem
    before = mod["path"].read_text(encoding="utf-8")
    try:
        run_packwiz("update", stem)
    except subprocess.CalledProcessError:
        print(f"  FAILED CF update {mod['name']}")
        return False
    after = mod["path"].read_text(encoding="utf-8")
    if before == after:
        return False
    # Verify CF file type isn't above channel (packwiz respects release-channel)
    print(f"  CF {mod['name']}: updated")
    return True


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--channel",
        choices=["release", "beta", "alpha"],
        default="release",
        help="Maximum instability allowed (default: release/stable only)",
    )
    ap.add_argument(
        "--dry-run",
        action="store_true",
        help="Only print what would update",
    )
    args = ap.parse_args()
    mc = read_pack()
    overrides = load_overrides()
    print(f"MC={mc} channel={args.channel} overrides={len(overrides)}")

    changed = 0
    for path in sorted(MODS.glob("*.pw.toml")):
        mod = parse_mod(path)
        # `pin = true` (packwiz's own pin flag) freezes a mod at its current file.
        # Unpin by deleting the line once a newer version has been tested.
        if re.search(r"^pin\s*=\s*true", mod["text"], re.M):
            print(f"  pinned, skip {mod['name']}")
            continue
        ch = effective_channel(mod, args.channel, overrides)
        # If override asks for more unstable than CLI, use the higher of the two for that mod only
        if channel_rank(ch) < channel_rank(args.channel):
            ch = args.channel
        if args.dry_run:
            if mod.get("mr_id") or mod.get("cf_project"):
                print(f" would check {mod['name']} as channel={ch}")
            continue
        if mod.get("mr_id"):
            if update_modrinth(mod, mc, ch):
                changed += 1
        elif mod.get("cf_project"):
            if update_curseforge(mod, mc, ch):
                changed += 1

    print("Refreshing index…")
    run_packwiz("refresh")
    print(f"Done. updates={changed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
