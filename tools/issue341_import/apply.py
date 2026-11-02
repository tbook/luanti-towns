#!/usr/bin/env python3
"""Apply a validated Issue 341 stage to the closed TownsWorkshop world."""
import argparse
import json
from pathlib import Path
import os
import shutil

from common import WORLDS, integrity_ok, sha256, world_is_open


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--stage', type=Path, required=True)
    ap.add_argument('--world', type=Path, default=WORLDS / 'TownsWorkshop')
    ap.add_argument('--backup', type=Path, default=Path('/tmp/towns-workshop-before-issue341'))
    args = ap.parse_args()
    world, stage = args.world.resolve(), args.stage.resolve()
    if world_is_open(world):
        raise SystemExit('TownsWorkshop is open; return to the menu before applying the import.')
    if (stage / 'PROVISIONAL').exists():
        raise SystemExit('This stage was made while the world was open. Close the game and re-run stage.py.')
    report = json.loads((stage / 'issue341-validation.json').read_text())
    if (report.get('buildings') != 3 or report.get('place_failures') or report.get('verify_failures')
            or report.get('node_mismatches') or report.get('inventory_mismatches')
            or not report.get('outside_unchanged_place_pass') or not report.get('outside_unchanged_reloaded_pass')
            or report.get('provisional')):
        raise SystemExit('Stage validation did not pass: ' + json.dumps({k: v for k, v in report.items() if k != 'records'}))
    if not integrity_ok(stage / 'map.sqlite'):
        raise SystemExit('Staged map database failed its integrity check.')
    if sha256(stage / 'map.sqlite') != (stage / 'stage-map.sha256').read_text().strip():
        raise SystemExit('Staged map changed after validation.')
    if sha256(world / 'map.sqlite') != (stage / 'source-map.sha256').read_text().strip():
        raise SystemExit('TownsWorkshop changed since the stage was prepared; refusing to overwrite it. Re-run stage.py.')
    if args.backup.exists():
        raise SystemExit('Backup already exists: ' + str(args.backup))
    artifacts = [stage / 'issue341-import.md', stage / 'issue341-validation.json']
    artifacts += sorted((stage / 'schems').glob('issue341_*'))
    targets = [world / p.name if p.parent == stage else world / 'schems' / p.name for p in artifacts]
    for target in targets:
        if target.exists():
            raise SystemExit('Refusing to overwrite existing workshop artifact: ' + str(target))
    (world / 'schems').mkdir(exist_ok=True)
    args.backup.mkdir(parents=True)
    shutil.copy2(world / 'map.sqlite', args.backup / 'map.sqlite')
    (args.backup / 'map.sha256').write_text(sha256(args.backup / 'map.sqlite') + '\n')
    db_tmp = world / 'map.issue341.sqlite'
    shutil.copy2(stage / 'map.sqlite', db_tmp)
    if sha256(db_tmp) != sha256(stage / 'map.sqlite'):
        db_tmp.unlink()
        raise SystemExit('Could not copy the staged map database intact.')
    os.replace(db_tmp, world / 'map.sqlite')
    if sha256(world / 'map.sqlite') != sha256(stage / 'map.sqlite') or not integrity_ok(world / 'map.sqlite'):
        rollback = world / 'map.issue341.rollback.sqlite'
        shutil.copy2(args.backup / 'map.sqlite', rollback)
        os.replace(rollback, world / 'map.sqlite')
        raise SystemExit('Applied map did not match the validated stage; restored the backup.')
    for source, target in zip(artifacts, targets):
        shutil.copy2(source, target)
    print('Applied 3 Issue 341 buildings to', world)
    print('Backup:', args.backup)
    print('Notes:', world / 'issue341-import.md')
    print('Teleport: (110, 10, 495), (145, 10, 495), (188, 10, 495)')


if __name__ == '__main__':
    main()
