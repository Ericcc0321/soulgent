# Developer tools

Tools for maintainers; not needed to build, run or use Soulgent.

Run them from the `app/` folder (each script changes into it by itself).

- `run-tests.sh`: runs a single group of checks from the program `test.sh` builds (`test.sh` itself takes no arguments), for example `tools/dev/run-tests.sh --zone-only`.
- `readme-shots.sh`: renders the README screenshots off screen, on the made-up `--demo-crowd`, in one language.
- `readme-gifs.sh`: renders the README animations (GIF/MP4, or short WebP loops) off screen from the program `test.sh` builds.
- `install-demo-pets.sh`: installs the demonstration pets into a folder of their own (never into `~/.petdex/pets`), for the two scripts above.
- `perf-check.sh`: measures the running panel's CPU use (idle and with the Seaview scene open) and the time of one `--dump`; changes and restarts nothing.
- `contact_sheet.py`: stitches frames captured by a `--capture-live` burst into one contact sheet image (needs Pillow).
- `orca_call.py`: sends one read-only request to Orca's local communication port and prints the reply.
- `orca_layouts.py`: lists the tab titles of each Orca workspace layout and the number of orphan terminals, for debugging the spotlight's tab matching (uses `orca_call.py`).

Also in `app/tools/`:

- `orca_clear_zone.swift`: works out, from an orca clip's film frames, the rectangles for `orca.json`'s `clear_zone` (where the crabs step aside); `--dry` only prints them.
