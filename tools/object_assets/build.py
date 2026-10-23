#!/usr/bin/env python3
"""Author the two small outdoor objects for issue #204; no world is modified.

Writes native MTS v4 schematics, runtime metadata, and diagram previews.
These objects are authored here, independently of captured building templates.
"""
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'schematics/objects'


def oak_tree():
    nodes = {(x, 0, z): ('mcl_core:dirt_with_grass', 0)
             for z in range(7) for x in range(7)}
    # Broad, slightly asymmetric crown; each mask is viewed from above.
    crowns = {
        4: ('.......', '..###..', '.#####.', '.#####.', '.#####.', '..###..', '.......'),
        5: ('..###..', '.#####.', '#######', '#######', '######.', '.#####.', '..###..'),
        6: ('...#...', '.#####.', '######.', '.######', '.#####.', '..###..', '.......'),
        7: ('.......', '..###..', '.#####.', '.#####.', '..###..', '...#...', '.......'),
        8: ('.......', '.......', '..###..', '..###..', '...#...', '.......', '.......'),
    }
    for y, rows in crowns.items():
        for z, row in enumerate(rows):
            for x, cell in enumerate(row):
                if cell == '#': nodes[x, y, z] = ('mcl_core:leaves', 0)
    for y in range(1, 7): nodes[3, y, 3] = ('mcl_core:tree', 0)
    # Upright branch stubs remain inside the crown.
    for p in ((2, 5, 3), (4, 5, 3), (3, 6, 2)):
        nodes[p] = ('mcl_core:tree', 0)
    return (7, 9, 7), 0, nodes


def garden():
    # Layer 0 seals the irrigation holes. Layer 1 is surrounding ground level.
    nodes = {(x, y, z): ('mcl_core:dirt' if y == 0 else 'mcl_core:dirt_with_grass', 0)
             for z in range(7) for y in range(2) for x in range(7)}
    for z in range(7): nodes[3, 1, z] = ('mcl_core:gravel', 0)
    for z in range(1, 6):
        for x in (1, 2, 4, 5):
            if (x, z) in ((2, 3), (4, 3)):
                nodes[x, 1, z] = ('mcl_core:water_source', 0)
            else:
                nodes[x, 1, z] = ('mcl_farming:soil_wet', 0)
                # Mostly established plants, with a few younger ones.
                stage = (x + z) % 3
                crop = ('wheat_4', 'wheat_6', 'wheat')[stage] if x < 3 else (
                    'carrot_3', 'carrot_6', 'carrot')[stage]
                nodes[x, 2, z] = ('mcl_farming:' + crop, 3)
    return (7, 3, 7), 1, nodes


def write_mts(path, size, nodes):
    names = sorted({'air'} | {name for name, _ in nodes.values()})
    ids = {name: i for i, name in enumerate(names)}
    sx, sy, sz = size
    ordered = [nodes.get((x, y, z), ('air', 0))
               for z in range(sz) for y in range(sy) for x in range(sx)]
    header = b'MTSM' + struct.pack('>4H', 4, sx, sy, sz) + bytes([127]) * sy
    header += struct.pack('>H', len(names))
    for name in names:
        encoded = name.encode('utf-8')
        header += struct.pack('>H', len(encoded)) + encoded
    raw = b''.join(struct.pack('>H', ids[name]) for name, _ in ordered)
    raw += bytes([127]) * len(ordered)  # Every node, including air, is deterministic.
    raw += bytes(p2 for _, p2 in ordered)
    path.write_bytes(header + zlib.compress(raw, 9))
    return [name for name in names if name != 'air']


COLORS = {'mcl_core:dirt': '#96704b', 'mcl_core:dirt_with_grass': '#80a653',
          'mcl_core:tree': '#80603e', 'mcl_core:leaves': '#588d3a',
          'mcl_core:gravel': '#adad9c', 'mcl_core:water_source': '#4b96c6',
          'mcl_farming:soil_wet': '#65482f'}


def preview(path, label, size, ground, nodes):
    """Isometric geometry diagram, not a screenshot of the game textures."""
    def point(x, y, z): return (240 + (x-z)*22, 290 + (x+z)*11 - (y-ground)*24)
    def polygon(points, color, opacity=1):
        pts = ' '.join(f'{x:.1f},{y:.1f}' for x, y in points)
        return f'<polygon points="{pts}" fill="{color}" opacity="{opacity}" stroke="#33402d" stroke-width=".5"/>'
    out = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 490" width="720" height="735">',
           '<rect width="480" height="490" fill="#f7f5ed"/>',
           f'<text x="24" y="32" font-family="sans-serif" font-size="20">{label}</text>']
    for (x, y, z), (name, _) in sorted(nodes.items(), key=lambda item: (sum(item[0]), item[0][1])):
        if name.startswith('mcl_farming:') and name != 'mcl_farming:soil_wet':
            px, py = point(x+.5, y-.45, z+.5)
            color = '#c6a848' if 'wheat' in name else '#4d8234'
            out.append(f'<path d="M{px},{py} v-15 m0,7 l-6,-6 m6,8 l6,-7" stroke="{color}" stroke-width="3" fill="none"/>')
            continue
        color = COLORS[name]
        # Only exposed faces; water is slightly below the surrounding surface.
        top = y + (.4 if name.endswith('water_source') else .5)
        faces = [((x+1,y,z), [(x+1,y-.5,z),(x+1,y-.5,z+1),(x+1,top,z+1),(x+1,top,z)]),
                 ((x,y,z+1), [(x,y-.5,z+1),(x+1,y-.5,z+1),(x+1,top,z+1),(x,top,z+1)]),
                 ((x,y+1,z), [(x,top,z),(x+1,top,z),(x+1,top,z+1),(x,top,z+1)])]
        for i, (neighbor, vertices) in enumerate(faces):
            above = nodes.get(neighbor, ('air', 0))[0]
            if above == 'air' or (above.startswith('mcl_farming:') and above != 'mcl_farming:soil_wet'):
                out.append(polygon([point(*p) for p in vertices], color))
                if i < 2: out.append(polygon([point(*p) for p in vertices], '#000000', .12 if i == 0 else .25))
    out += [f'<text x="24" y="447" font-family="sans-serif" font-size="14">{size[0]} × {size[1]} × {size[2]} nodes · ground row {ground}</text>',
            '<text x="24" y="471" font-family="sans-serif" font-size="12">Geometry diagram; game textures and plant shapes differ.</text>', '</svg>']
    path.write_text('\n'.join(out) + '\n')


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    catalog = ['-- Generated by tools/object_assets/build.py. Outdoor objects, not buildings.', 'return {']
    for ident, label, author in [('oak_tree', 'Oak tree', oak_tree), ('garden', 'Garden', garden)]:
        size, ground, nodes = author()
        required = write_mts(OUT / f'{ident}.mts', size, nodes)
        quoted = ', '.join('"' + name + '"' for name in required)
        (OUT / f'{ident}.lua').write_text('-- Generated by tools/object_assets/build.py.\nreturn {required_nodes = {' + quoted + '}}\n')
        sx, sy, sz = size
        catalog += [f'\t{ident} = {{id = "{ident}", label = "{label}",',
                    f'\t\tpath = "schematics/objects/{ident}.mts", data_path = "schematics/objects/{ident}.lua",',
                    f'\t\tsize = {{x = {sx}, y = {sy}, z = {sz}}}, ground_offset = {ground},',
                    '\t\tclearing = {x = 9, z = 9}},']
        preview(OUT / f'{ident}.svg', label, size, ground, nodes)
        print(f'{ident}: {sx} × {sy} × {sz}, ground row {ground}, {len(nodes)} non-air nodes')
    catalog.append('}')
    (OUT / 'catalog.lua').write_text('\n'.join(catalog) + '\n')


if __name__ == '__main__':
    main()
