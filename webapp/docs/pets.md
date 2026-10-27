# Pets and the Tool Figure

English | [简体中文](pets.zh-CN.md)

The pets in the Soulgent mobile app (session avatars, and the pet that walks out of its avatar frame while a session is Working in the SoulChat list) and the tool figure on the chat page all come from Petdex.
Pets on Petdex are community submissions, and each artwork belongs to the person who submitted it. This repository does not ship any Petdex pet images and does not hard-code any pet names. Many thanks to Petdex and to every artist who has contributed a pet.

If no pets are installed, the tool figure falls back to the Soulgent flame, a built-in original figure (`web/figures/soulflame/`), so it works out of the box.

Paths below are relative to the repository's `webapp/` folder; run the commands from there.

## 1. Install a pet

```sh
npx petdex install <id>      # <id> is the pet's name on Petdex
```

Installed pets live in `~/.petdex/pets/<id>/spritesheet.webp`. The repository's `app/pets/<id>/` (`../app/pets/<id>/` from `webapp/`) is an optional local source of extra pets. The built-in Soulgent flame lives in `app/brand/soulgent/pet/soulflame/` on the Mac side; the phone's built-in Soulgent flame figure is in `webapp/web/figures/soulflame/` and does not go through sprite cutting.

## 2. Slice them into small images for the phone

The script needs Pillow on the Mac's own Python (installing it in the Docker image doesn't help). Install it once from PyPI:

```sh
/usr/bin/python3 -m pip install --user Pillow
```

```sh
cd webapp                         # from the repository root
/usr/bin/python3 tools/build_pets.py
```

- By default it reads `../app/pets` and then `~/.petdex/pets` (if two pets share a name, the first one found wins), and writes `data/pets/<id>/{0,1,2,3,4,6,7,still}.webp` and `data/pets/manifest.json`.
- `data/pets/` is not tracked in git; Caddy serves it to the phone under `/pets/`.
- Unchanged pets are skipped, so re-running is fast. If you replace a pet's images but keep its name, the phone will still have the old ones cached; rename `PET_CACHE` in `web/sw.js` to force an update.

## 3. Choose the tool figure

```sh
/usr/bin/python3 tools/build_pets.py --figure <id>    # use this pet as the tool figure
/usr/bin/python3 tools/build_pets.py --figure ""      # clear the choice and go back to automatic
```

The chosen pet gets a `figure` field in its `manifest.json` entry, and later runs without `--figure` keep that choice. The phone picks the figure like this:

1. The pet with `figure` in the manifest (it must have all 7 sprite rows);
2. If none is chosen: the first complete pet, sorted by name;
3. If no pets are installed at all (`/pets/manifest.json` is missing or empty): the built-in flame.

You can describe the figure's geometry (where its feet are, how much of it shows when it sits under a chat bubble, whether to crop a prop above its head) in `data/pets/<id>/figure.json`, and build_pets will put it into the `figure` field. Every field is optional; see `FIG_GEOM_DEFAULT` in `web/logic.js` for the defaults and what each field means. The built-in flame's config is `web/figures/soulflame/figure.json`, which you can use as a template.

## 4. Pet abilities (walking out in the SoulChat list)

When a session with no zone is Working, its pet walks out of the avatar frame. Which pets can walk is set in `data/pets/<id>/caps.json`:

```json
{"walk": true}
```

- `walk`: row 7 ("working") of the sprite sheet is a walk cycle → the pet heads out on errands / carries files;
- Anything else (`unsure`, or no caps.json): the pet stays in its avatar and the built-in Soulgent flame runs the errand for it.

After editing, re-run build_pets.py and the caps are collected into the manifest.

## 5. Push notification emoji

iPhone lock-screen notifications cannot show the avatar, so each session push title starts with an emoji picked from its pet (no pet: 🔥); to choose one yourself, write `data/pet-emoji.json` as `{"<pet id>": "🐳"}` (optional, private, read by the api on change).
