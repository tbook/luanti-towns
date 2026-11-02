#!/usr/bin/env python3
"""Re-export the Temple of Jupiter, Temple of Vesta and Hippodrome from TownsWorkshop.

Thin wrapper over the general tool (#377):

    python3 tools/issue341_import/update.py
    == python3 tools/reimport.py apply --ids temple_of_jupiter,temple_of_vesta,hippodrome

With the game closed it scans around the three FIXED_BOXES boxes (refusing on possible
clipped architecture), re-exports just these ids with export_roman.py --only, gates that
nothing else under schematics/ or in the manifests changed, and runs roman_check.
The workshop and Creative worlds are never modified. See `tools/reimport.py --help`.
"""
import argparse
from pathlib import Path
import sys

from common import ENGINE, ROOT, WORLDS

sys.path.insert(0, str(ROOT / 'tools'))
import reimport  # noqa: E402

IDS = ('temple_of_jupiter', 'temple_of_vesta', 'hippodrome')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--world', type=Path, default=WORLDS / 'TownsWorkshop')
    ap.add_argument('--engine', default=ENGINE)
    ap.add_argument('--margin', type=int, default=reimport.SCAN_MARGIN)
    args = ap.parse_args()
    reimport.apply(list(IDS), args.world.resolve(), args.engine, margin=args.margin)


if __name__ == '__main__':
    main()
