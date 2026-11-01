#!/usr/bin/env python3
"""Capture the Issue 341 source bounds from read-only world snapshots."""
import argparse
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WORLDS = Path.home() / 'Library/Application Support/minetest/worlds'


def snapshot(source, target):
    for name in ('world.mt', 'map_meta.txt'):
        shutil.copy2(source / name, target / name)
    with sqlite3.connect((source / 'map.sqlite').as_uri() + '?mode=ro', uri=True) as src:
        with sqlite3.connect(target / 'map.sqlite') as dst:
            src.backup(dst)


def run_capture(engine, port, source_name, jobs, output):
    work = Path(tempfile.mkdtemp(prefix='towns-issue341-capture-'))
    source = WORLDS / source_name
    snapshot(source, work)
    (work / 'issue341.json').write_text(json.dumps(jobs))
    (work / 'schems').mkdir()
    mod = work / 'worldmods/issue341_capture'
    mod.mkdir(parents=True)
    shutil.copy2(HERE / 'capture.lua', mod / 'init.lua')
    (mod / 'mod.conf').write_text('name = issue341_capture\n')
    with (work / 'world.mt').open('a') as f:
        f.write('\nload_mod_issue341_capture = worldmods/issue341_capture\n')
    (work / 'capture.conf').write_text('enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')
    with (work / 'stdout.log').open('w') as log:
        proc = subprocess.run([engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
                               '--config', str(work / 'capture.conf'), '--port', str(port),
                               '--logfile', str(work / 'engine.log')], stdout=log,
                              stderr=subprocess.STDOUT, timeout=240)
    report = work / 'issue341-report.json'
    if proc.returncode or not report.exists():
        raise RuntimeError('Capture failed; inspect ' + str(work / 'engine.log'))
    records = json.loads(report.read_text())
    for record in records:
        shutil.copy2(work / 'schems' / (record['id'] + '.mts'), output / (record['id'] + '.mts'))
    return records


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    ap.add_argument('--port', type=int, default=39491)
    ap.add_argument('--output', type=Path, default=Path('/tmp/towns-issue341'))
    args = ap.parse_args()
    jobs = json.loads((HERE / 'buildings.json').read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    all_records = []
    for name in ('Home', 'Creative'):
        subset = [j for j in jobs if j['source'] == name]
        if subset:
            all_records.extend(run_capture(args.engine, args.port, name, subset, args.output))
            args.port += 1
    (args.output / 'captures.json').write_text(json.dumps(all_records, indent=2) + '\n')
    for record in all_records:
        print('%s: %s x %s x %s at source %s..%s; %d metadata nodes, %d door nodes' %
              (record['id'], record['size']['x'], record['size']['y'], record['size']['z'],
               record['min'], record['max'], len(record.get('metadata') or []),
               len(record.get('doors') or [])))


if __name__ == '__main__':
    main()
