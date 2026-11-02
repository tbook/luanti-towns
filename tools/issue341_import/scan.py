#!/usr/bin/env python3
"""Scan a read-only snapshot of TownsWorkshop around the three #341 boxes.

Reports non-natural nodes outside each recorded FIXED_BOXES box (within --margin),
so an edit that grew past the box is reported rather than silently exported.
Exit status 1 when anything is found outside a box.
"""
import argparse
import json
from pathlib import Path
import shutil
import sys
import tempfile

from common import ENGINE, HERE, ROOT, WORLDS, copy_world, install_helper, run_server, world_is_open

sys.path.insert(0, str(ROOT / 'tools/issue139_import'))
import export_roman  # noqa: E402

IDS = ('temple_of_jupiter', 'temple_of_vesta', 'hippodrome')


def scan(world, engine=ENGINE, port=39498, margin=8):
    work = Path(tempfile.mkdtemp(prefix='towns-issue341-scan-'))
    shutil.rmtree(work)
    if copy_world(world, work) is None:
        raise SystemExit('TownsWorkshop map changed while it was being copied; close the game and retry.')
    boxes = [{'id': i, 'min': export_roman.FIXED_BOXES[i][0], 'max': export_roman.FIXED_BOXES[i][1]} for i in IDS]
    (work / 'issue341-scan-job.json').write_text(json.dumps({'margin': margin, 'buildings': boxes}))
    install_helper(work, 'issue341_scan', HERE / 'scan.lua')
    run_server(work, port, engine)
    out = work / 'issue341-scan.json'
    if not out.exists():
        raise SystemExit('Scan failed; inspect ' + str(work / 'engine.log'))
    return json.loads(out.read_text())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--world', type=Path, default=WORLDS / 'TownsWorkshop')
    ap.add_argument('--engine', default=ENGINE)
    ap.add_argument('--port', type=int, default=39498)
    ap.add_argument('--margin', type=int, default=8)
    args = ap.parse_args()
    if world_is_open(args.world):
        raise SystemExit('TownsWorkshop is open; return to the menu first.')
    report = scan(args.world, args.engine, args.port, args.margin)
    for r in report:
        print(json.dumps(r, sort_keys=True))
    return 1 if any(r['outside'] for r in report) else 0


if __name__ == '__main__':
    sys.exit(main())
