# Spawn level probe (issue 448)

Checks whether `core.get_spawn_level(x, z)` is a usable cheap ocean pre-screen
for automatic town candidates (#431). The write-up is
`docs/automatic_towns_spawn_level_probe.md`.

## What it does

For each seed in `sites.json`, `probe.py`:

1. Builds a new disposable world under `--scratch-root` (it must not exist).
   The world's `world.mt` settings and `map_meta.txt` come from
   `--source-world`, with the towns and living_villages mods left out. No
   `map.sqlite` is copied, and the source world is never opened.
2. Runs the real engine headless (`--server`, `mineclone2`) on its own port
   with `probe.lua` as a world mod.
3. `probe.lua` then:
   - calls `get_spawn_level` on 9 points per site (3x3 grid, offsets -132, 0,
     +132) from a `core.after` timer callback, timing each call (best of 5);
   - calls it from `on_generated` for the first chunks, from the emerge thread;
   - emerges each sample column and reads the generated column (y -32..80) as
     engine ground truth: `ocean` when water is above the highest solid node,
     `land` for dry ground, `none` or `unloaded` otherwise.
4. Writes `spawn_level_probe.json` in the scratch world and shuts the server
   down. `probe.py` merges it with a summary per site.

With `--saved-map` (a SQLite copy of a saved world with the same seed), the same
columns are also classified from saved terrain. This checks that the scratch
world generates the same terrain as the save.

## Running

Snapshot the saved world first. Do not point the probe at the live save:

    sqlite3 "$HOME/Library/Application Support/minetest/worlds/Testlandia/map.sqlite" \
      ".backup /path/to/scratch/testlandia_map.sqlite"

Then run one seed at a time or all of them:

    python3 tools/spawn_level_probe/probe.py \
      --scratch-root /path/to/scratch/spawn_probe/runs \
      --saved-map /path/to/scratch/testlandia_map.sqlite \
      --only-seed 14993866105032827525 --port 39471

The Roman town seed (11605533223103715697) has no saved world in this
environment. It runs without `--saved-map` and its ground truth is what the
engine generates, using the source world's `map_meta.txt` with only the seed
replaced. The real noise parameters of that world are not known.

Requirements: the Luanti binary at `/Applications/luanti.app`, and Python 3.14
or later for `compression.zstd` (only used by `--saved-map`).
