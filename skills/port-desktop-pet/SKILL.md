---
name: port-desktop-pet
description: Port a desktop pet into AINEMATE (this SwiftUI desktop pet) by remapping or building its art as a Codex v2 sprite atlas — 1536x2288, 8 columns x 11 rows of 192x208 cells — then installing it under ~/.aimate/pets and validating it with the bundled scripts. Use when the user wants to import a pet they hatched in Codex/ChatGPT, convert a spritesheet, GIF or character image into a pet, fix a pet that shows the red error dot, or asks whether a Codex pet package works here.
---

# Port a desktop pet

## Overview

The app plays Codex's v2 custom-pet format. Two paths only: a package that is
already v2 gets installed as-is; everything else gets laid out on the 8x11 grid
with the scripts in `scripts/`.

## What the app accepts

- Search order: `${CODEX_HOME:-~/.codex}/pets/<id>/`, then `~/.aimate/pets/<id>/`.
- Package: `pet.json` + sheet, a directory holding one image, or a loose
  `.webp`/`.png` in a pets directory.
- Sheet: **1536x2288 exactly**, 8 columns x 11 rows of 192x208, PNG or WebP,
  transparent background. The app trusts pixels only — `spriteVersionNumber` is
  ignored, so a 1536x1872 (v1) sheet is rejected.
- On a rejected sheet the pet keeps its previous art and shows a red dot in the
  corner whose tooltip is the decode error.

## Atlas contract

| Row | Meaning | Frames played | Columns |
| --- | --- | --- | --- |
| 0 | idle | 6 | 0–5 |
| 1 | running left | 8 | 0–7 |
| 2 | running right | 8 | 0–7 |
| 3 | waving | 4 | 0–3 |
| 4 | jumping | 5 | 0–4 |
| 5 | failed | 8 | 0–7 |
| 6 | waiting for you | 6 | 0–5 |
| 7 | working | 6 | 0–5 |
| 8 | needs review | 6 | 0–5 |
| 9 | look 0°–157.5° | 8 | 0–7 |
| 10 | look 180°–337.5° | 8 | 0–7 |

- Frame durations are compiled into the app (`AtlasLayout.swift`); do not ship a
  timing file.
- 0° is straight up (12 o'clock); "no direction" is a deadzone that falls back
  to idle, so there is no front-facing look cell.
- Cells the app never plays must be fully transparent, not white.

## Workflow

1. **Inspect the input.** `sips -g pixelWidth -g pixelHeight <file>`; also check
   it has an alpha channel. If it is already 1536x2288, jump to step 5.
2. **A sheet in another layout** (8x9, 4xN, arbitrary grid): slice it with
   `swift scripts/slice_sheet.swift <sheet> <cols> <rows> <out-dir> [cellWxH]`,
   then copy `out/oldRow/oldCol.png` onto the new `<row>/<col>.png` names.
3. **A GIF or a few images**: extract/choose one pose set per row. If a row needs
   more frames than you have, repeat frames (2-3x) rather than leaving cells
   empty; the app plays every listed column.
4. **Generate missing frames** only when asked. Keep one character, one scale,
   feet on the same baseline in every row, and an empty margin of a few pixels
   inside each 192x208 cell. Never bake a scene background.
5. **Assemble:**
   `swift scripts/build_atlas.swift <frames-dir> <out.png>`
   where `frames-dir/<row>/<col>.png` holds the cells. Cell-sized frames land
   pixel-exact; smaller ones are centred at their aspect ratio.
6. **Validate:** `swift scripts/validate_atlas.swift <out.png>` — it must print
   `PASS`. It checks dimensions, empty played cells, the 16 look poses and an
   opaque background. Fix everything it fails; treat edge-touch notes as a
   warning that art may be clipped.
7. **Install:** create `~/.aimate/pets/<id>/` with the sheet and:

   ```json
   {
     "id": "<id>",
     "displayName": "<Name>",
     "description": "<one sentence>",
     "spriteVersionNumber": 2,
     "spritesheetPath": "spritesheet.png"
   }
   ```

   `<id>` is lowercase-hyphen (`my-otter`). Never overwrite an existing pet
   folder, never touch `dist/` or `02_assets/dev_only_pets`, and ask before
   deleting anything already installed.
8. **Hand off:** tell the user to right-click the pet → 「重新扫描宠物」 (or just
   reopen the menu) → pick the new name under 「宠物」. No relaunch needed.

## Rules

- Do not claim success without a `PASS` from the validator and an actual crop
  check of the installed sheet.
- Do not rename or restyle a pet the user already has; add a new id.
- If the source art is a photorealistic or copyrighted character sheet, say so
  before installing.

## Resources

- `scripts/build_atlas.swift` — frames dir → 1536x2288 PNG.
- `scripts/slice_sheet.swift` — any grid sheet → per-cell PNGs.
- `scripts/validate_atlas.swift` — contract check; exit 0 = usable, 1 = rejected.
- `docs/pets.md` — the same contract for humans, in Chinese.
