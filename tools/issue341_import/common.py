"""Shared helpers for the Issue 341 workshop tooling."""
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
WORLDS = Path.home() / 'Library/Application Support/minetest/worlds'
ENGINE = '/Applications/luanti.app/Contents/MacOS/luanti'


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def world_is_open(world):
    opened = subprocess.run(['lsof', '-F', 'n', str(Path(world) / 'map.sqlite')], capture_output=True, text=True)
    # lsof exits 1 with no output when nothing has the file open.
    return opened.returncode != 1 or bool(opened.stdout)


def copy_world(source, target):
    """Copy a world's map through SQLite's backup API (safe to read while open).

    Returns the sha256 of the source map.sqlite file read *before* the backup,
    or None if the source file changed while copying.
    """
    source, target = Path(source), Path(target)
    target.mkdir(parents=True)
    for name in ('world.mt', 'map_meta.txt'):
        shutil.copy2(source / name, target / name)
    before = sha256(source / 'map.sqlite')
    with sqlite3.connect((source / 'map.sqlite').as_uri() + '?mode=ro', uri=True) as src:
        with sqlite3.connect(target / 'map.sqlite') as dst:
            src.backup(dst)
    after = sha256(source / 'map.sqlite')
    return before if before == after else None


def install_helper(world, name, lua_path):
    """Install a one-shot helper mod into a disposable world."""
    mod = Path(world) / 'worldmods' / name
    mod.mkdir(parents=True)
    shutil.copy2(lua_path, mod / 'init.lua')
    (mod / 'mod.conf').write_text('name = %s\n' % name)
    with (Path(world) / 'world.mt').open('a') as f:
        f.write('\nload_mod_%s = worldmods/%s\n' % (name, name))
    (Path(world) / 'helper.conf').write_text('enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')


def run_server(world, port, engine=ENGINE, timeout=900):
    world = Path(world)
    with (world / 'stdout.log').open('w') as log:
        proc = subprocess.run([engine, '--server', '--world', str(world), '--gameid', 'mineclone2',
                               '--config', str(world / 'helper.conf'), '--port', str(port),
                               '--logfile', str(world / 'engine.log')], stdout=log,
                              stderr=subprocess.STDOUT, timeout=timeout)
    return proc.returncode


def integrity_ok(map_path):
    with sqlite3.connect(map_path) as db:
        return db.execute('pragma integrity_check').fetchone()[0] == 'ok'
