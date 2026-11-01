#!/usr/bin/env python3
"""Re-export the Temple of Jupiter, Temple of Vesta and Hippodrome from TownsWorkshop.

One command, run from the Towns checkout with the game closed:

    python3 tools/issue341_import/update.py

1. scan.py: reads a SQLite snapshot of the workshop and refuses to continue if any
   non-natural node lies within --margin of a recorded FIXED_BOXES box but outside
   it (an edit that outgrew its box must be handled by changing FIXED_BOXES).
2. export_roman.py --only: re-captures just these three ids, rewriting their
   .mts/.lua files and their own manifest records.
3. roman_check/run.py: places every Roman landmark at four rotations in a scratch world.
4. Confirms that no other Roman manifest record or schematic changed.

The workshop and Creative worlds are never modified. Afterwards run
`lua5.1 tests/run.lua` and review `git diff`; update catalog.lua if sizes or
entrances moved.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from common import ENGINE, ROOT, WORLDS, world_is_open
import scan

IDS = scan.IDS
ROMAN = ROOT / 'schematics/imports/roman'


def records():
    return {b['id']: b for b in json.loads((ROMAN / 'manifest.json').read_text())['buildings']}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--world', type=Path, default=WORLDS / 'TownsWorkshop')
    ap.add_argument('--engine', default=ENGINE)
    ap.add_argument('--margin', type=int, default=8)
    args = ap.parse_args()
    if world_is_open(args.world):
        raise SystemExit('TownsWorkshop is open; return to the menu first.')
    report = scan.scan(args.world, args.engine, margin=args.margin)
    stray = [r for r in report if r['outside']]
    for r in report:
        print('%s: %d non-air nodes in box, %d non-natural nodes outside it' % (r['id'], r['inside_non_air'], r['outside']))
    if stray:
        raise SystemExit('Nodes outside the recorded boxes (no export done):\n' + json.dumps(stray, indent=1))
    before = records()
    py = sys.executable
    subprocess.run([py, str(ROOT / 'tools/issue139_import/export_roman.py'), '--world', str(args.world),
                    '--engine', args.engine, '--only', *IDS], check=True)
    after = records()
    changed = [i for i in before if i not in IDS and before[i] != after.get(i)]
    if changed:
        raise SystemExit('Unrelated manifest records changed: ' + ', '.join(changed))
    subprocess.run([py, str(ROOT / 'tools/roman_check/run.py'), '--engine', args.engine], check=True)
    for i in IDS:
        r = after[i]
        s = r['size']
        print('%s: %dx%dx%d, %d metadata nodes' % (i, s['x'], s['y'], s['z'], r['metadata_nodes']))
    print('Done. Run tests/run.lua and review git diff; catalog.lua entrances/ground_offset are not recomputed.')


if __name__ == '__main__':
    main()
