#!/usr/bin/env python3
"""Import the Issue 439 Roman palace from TownsWorkshop into the template catalog.

Import only: the building gets a catalog entry and a schematic, with no role,
so no planner or town type selects it. Nothing here places it.

Steps:
1. check that buildings.json here matches the entry in
   tools/workshop_export/buildings.json (the exporter reads only that file);
2. run the workshop exporter for these ids only, with runtime validation;
3. print the generated catalog entry and manifest record for review.

Close TownsWorkshop first so its saved map is what gets read.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from common import EXPORTER, HERE, ENGINE, ROOT, WORLDS, world_is_open

CONFIG = ROOT / 'tools/workshop_export/buildings.json'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--world', type=Path, default=WORLDS / 'TownsWorkshop')
    ap.add_argument('--engine', default=ENGINE)
    ap.add_argument('--port', type=int, default=39487)
    ap.add_argument('--no-validate', action='store_true', help='Skip the runtime placement check')
    args = ap.parse_args()

    if world_is_open(args.world):
        raise SystemExit(args.world.name + ' is open; return to the menu before importing.')

    record = json.loads((HERE / 'buildings.json').read_text())
    exporter_config = {b['id']: b for b in json.loads(CONFIG.read_text())['buildings']}
    for entry in record:
        if exporter_config.get(entry['id']) != entry:
            raise SystemExit('tools/workshop_export/buildings.json has no entry matching %r; '
                             'copy tools/issue439_import/buildings.json into it first.' % entry['id'])

    ids = [entry['id'] for entry in record]
    command = [sys.executable, str(EXPORTER), '--world', str(args.world), '--engine', args.engine,
               '--port', str(args.port), '--only', *ids]
    if not args.no_validate:
        command.append('--validate')
    result = subprocess.run(command)
    if result.returncode:
        raise SystemExit('Export failed (exit %d)' % result.returncode)

    catalog = ROOT / 'schematics/templates/catalog.lua'
    manifest = json.loads((ROOT / 'schematics/templates/manifest.json').read_text())
    for entry in record:
        found = [r for r in manifest['buildings'] if r['id'] == entry['id']]
        if len(found) != 1:
            raise SystemExit('Manifest has no single record for %s' % entry['id'])
        print('Manifest record:', json.dumps({k: found[0].get(k) for k in
                                              ('id', 'size', 'entrance', 'entrance_kind', 'source_min',
                                               'source_max', 'verified_nodes')}, sort_keys=True))
    print('Catalog:', catalog)


if __name__ == '__main__':
    main()
