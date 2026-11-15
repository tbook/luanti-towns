#!/usr/bin/env python3
"""Survey TownsWorkshop for the Roman palace and print its real bounds.

Works only on a disposable copy under --scratch (the new directory must not
exist). The default box is the ticket's approximate box (307,7,497)-(371,30,554)
with a 16-node margin on every side, so the true edges are found rather than
assumed. Read the bounds, doors and counts, then set scan_min/scan_max and the
entrance in tools/workshop_export/buildings.json (see README.md).
"""
import argparse
import json
from pathlib import Path

from common import ENGINE, HERE, WORLDS, copy_world, install_helper, run_server, world_is_open

MARGIN = 16


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--world', type=Path, default=WORLDS / 'TownsWorkshop')
    ap.add_argument('--scratch', type=Path, required=True, help='New directory for the disposable copy')
    ap.add_argument('--engine', default=ENGINE)
    ap.add_argument('--port', type=int, default=39499)
    ap.add_argument('--min', nargs=3, type=int, default=[307, 7, 497])
    ap.add_argument('--max', nargs=3, type=int, default=[371, 30, 554])
    ap.add_argument('--slice-y', nargs='+', type=int, default=[9, 10, 15],
                    help='Y levels to write as plan slices (D door, # structure, . air or ground)')
    args = ap.parse_args()
    if world_is_open(args.world):
        raise SystemExit(args.world.name + ' is open; return to the menu before surveying.')
    if args.scratch.exists():
        raise SystemExit('Scratch directory already exists: ' + str(args.scratch))
    lo = [args.min[0] - MARGIN, args.min[1] - MARGIN, args.min[2] - MARGIN]
    hi = [args.max[0] + MARGIN, args.max[1] + MARGIN, args.max[2] + MARGIN]
    copy_world(args.world, args.scratch)
    job = {'min': dict(zip('xyz', lo)), 'max': dict(zip('xyz', hi)), 'slice_y': args.slice_y}
    (args.scratch / 'issue439-survey-job.json').write_text(json.dumps(job))
    install_helper(args.scratch, 'issue439_survey', HERE / 'survey.lua')
    rc = run_server(args.scratch, args.port, args.engine)
    report_path = args.scratch / 'issue439-survey.json'
    if rc or not report_path.exists():
        raise SystemExit('Survey failed; inspect ' + str(args.scratch / 'engine.log'))
    report = json.loads(report_path.read_text())
    print('Non-natural nodes:', report['non_natural_nodes'])
    print('Bounds (min, max):', report['bounds']['min'], report['bounds']['max'])
    print('Doors (any height):', len(report['doors']))
    print('Survey (full report):', report_path)


if __name__ == '__main__':
    main()
