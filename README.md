# The Illustrious MFPack (packwiz)

NeoForge **1.21.1** pack for MFServer (Modrinth + CurseForge, including [Create: Lanterns](https://www.curseforge.com/minecraft/mc-mods/create-lanterns)).

## Pack URL

```
https://app-renticeship.github.io/mfpack-packwiz/pack.toml
```

(Also: https://app-renticeship.github.io/mfpack-packwiz/pack.toml )

## Players — Prism (no extra scripts)

Your instance pre-launch already runs packwiz-installer. On every Play, mods sync.

To wire a fresh instance: put `packwiz-installer-bootstrap.jar` in `minecraft/`, enable Custom Commands, pre-launch:

```
"$INST_JAVA" -jar packwiz-installer-bootstrap.jar https://app-renticeship.github.io/mfpack-packwiz/pack.toml
```

## Server (Pelican)

Startup command:

```
bash .mfpack-update/start.sh
```

## Maintainers

Mods never update on their own and there is no whole-pack update. The [Pages console](https://app-renticeship.github.io/mfpack-packwiz/)
lists every mod with a newer Modrinth or CurseForge file (from `updates.json`, written by a scan) and updates them one at a time
through the *Update mods* workflow (`mode=update`, `mods=slug@version`). Don't run `packwiz update --all`.

Adding a mod by hand:

```
packwiz curseforge add <slug-or-cf-url> -y
packwiz modrinth add <slug-or-url> -y
packwiz refresh
git add -A && git commit --trailer "Co-authored-by: Cursor <cursoragent@cursor.com>" -m "chore: update mods" && git push
```

