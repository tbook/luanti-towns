#!/usr/bin/env python3
"""Survey a copy of TownsWorkshop for columns holding non-natural nodes.

Reads the workshop through SQLite's backup API (safe while the game is open)
and works only on a disposable copy under --scratch.
"""
import argparse
import json
from pathlib import Path

from common import ENGINE, HERE, WORLDS, copy_world, install_helper, run_server


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--world', type=Path, default=WORLDS / 'TownsWorkshop')
    ap.add_argument('--scratch', type=Path, required=True, help='New directory for the disposable copy')
    ap.add_argument('--engine', default=ENGINE)
    ap.add_argument('--port', type=int, default=39495)
    ap.add_argument('--min', nargs=3, type=int, default=[0, 7, 80])
    ap.add_argument('--max', nargs=3, type=int, default=[560, 90, 560])
    args = ap.parse_args()
    if args.scratch.exists():
        raise SystemExit('Scratch directory already exists: ' + str(args.scratch))
    copy_world(args.world, args.scratch)
    job = {'min': dict(zip('xyz', args.min)), 'max': dict(zip('xyz', args.max))}
    (args.scratch / 'issue341-survey-job.json').write_text(json.dumps(job))
    install_helper(args.scratch, 'issue341_survey', HERE / 'survey.lua')
    rc = run_server(args.scratch, args.port, args.engine)
    report = args.scratch / 'issue341-survey.json'
    if rc or not report.exists():
        raise SystemExit('Survey failed; inspect ' + str(args.scratch / 'engine.log'))
    print(json.dumps(json.loads(report.read_text())['other'], indent=1, sort_keys=True))
    print('Survey:', report)


if __name__ == '__main__':
    main()
