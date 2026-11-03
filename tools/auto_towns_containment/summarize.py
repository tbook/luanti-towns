#!/usr/bin/env python3
"""Summarize containment-summary.json files from run.py.

Prints one row per sample (status, envelope chunks, worst-case chunks over every alignment
of the town to the engine chunk grid, node counts) and a per-stage table of actual reach
beyond plan.bounds against the envelope's stage_reach. --digest writes the compact JSON.

  summarize.py LABEL=path/to/containment-summary.json ... [--digest out.json]
"""
import argparse
import json
from pathlib import Path


def chunk(v):
    return (v + 32) // 80  # floor division handles negatives


def chunks_of(boxes, dx=0, dy=0, dz=0):
    seen = set()
    for b in boxes:
        lo, hi = b['min'], b['max']
        for kx in range(chunk(lo['x'] + dx), chunk(hi['x'] + dx) + 1):
            for ky in range(chunk(lo['y'] + dy), chunk(hi['y'] + dy) + 1):
                for kz in range(chunk(lo['z'] + dz), chunk(hi['z'] + dz) + 1):
                    seen.add((kx, ky, kz))
    return len(seen)


def worst_alignment(boxes, step):
    best = (0, None)
    for dx in range(0, 80, step):
        for dz in range(0, 80, step):
            for dy in range(0, 80, step):
                n = chunks_of(boxes, dx, dy, dz)
                if n > best[0]:
                    best = (n, (dx, dy, dz))
    return best


def base(name):
    return name.split('[')[0]


def interval(sample, label):
    for iv in sample.get('intervals') or []:
        if iv['label'] == label:
            return iv
    return None


def stage_reach_actual(sample):
    """Furthest horizontal reach beyond plan.bounds of nodes each stage wrote, from the
    per-stage snapshot intervals. Stages that share an interval (walls, wall_approaches,
    wall_features, outside_roads) are separated by exclusive membership of one box."""
    out = {}
    pairs = (('urban', 'urban_build'), ('margins', 'city_margins'), ('rural', 'outskirts'))
    for label, stage in pairs:
        iv = interval(sample, label)
        if iv is not None:
            out[stage] = iv['max_reach']
    iv = interval(sample, 'walls_or_roads')
    if iv is not None:
        for stage, reach in (iv.get('max_reach_base') or {}).items():
            out[stage] = reach
        out['walls_or_roads (any node)'] = iv['max_reach']
    return out


def inspection_check(sample):
    iv = sample.get('inspection_volume')
    rd = (sample.get('envelope') or {}).get('stages', {}).get('urban_read')
    if not iv or not rd:
        return None
    lo, hi = iv.get('minp') or iv.get('min'), iv.get('maxp') or iv.get('max')
    box = rd['box']
    return all(box['min'][a] <= lo[a] and hi[a] <= box['max'][a] for a in 'xyz')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('summaries', nargs='+')
    ap.add_argument('--step', type=int, default=8, help='alignment step in nodes (default 8)')
    ap.add_argument('--digest', type=Path)
    args = ap.parse_args()
    rows = []
    for item in args.summaries:
        label, path = item.split('=', 1) if '=' in item else (None, item)
        data = json.loads(Path(path).read_text())
        for s in data['samples']:
            rows.append((label or data['family'], data['family'], s))
    digest = []
    print('%-28s %4s %-9s %6s %6s %8s %6s %7s %7s %7s %4s' % (
        'run', 'seed', 'status', 'chunks', 'worst', 'changed', 'nonliq', 'reflow', 'overrun', 'int_out', 'feat'))
    for label, family, s in rows:
        if s.get('status') == 'no_site':
            print('%-28s %4s no_site (not a sample)' % (label, s.get('seed')))
            digest.append({'run': label, 'family': family, 'seed': s.get('seed'), 'status': 'no_site'})
            continue
        e = s.get('envelope') or {}
        out = s.get('outside') or {}
        ch = s.get('changed') or {}
        boxes = [v['box'] for v in (e.get('stages') or {}).values()]
        worst = worst_alignment(boxes, args.step) if boxes else (None, None)
        print('%-28s %4s %-9s %6s %6s %8s %6s %7s %7s %7s %4s' % (
            label, s.get('seed'), s.get('status'), e.get('chunks'), worst[0], ch.get('nodes'),
            out.get('non_liquid'), out.get('liquid_reflow'), s.get('stage_overrun_nodes'),
            s.get('interval_outside_nodes'), s.get('feature_count') if s.get('has_wall') else '-'))
        digest.append({
            'run': label, 'family': family, 'seed': s.get('seed'), 'status': s.get('status'),
            'build_ok': s.get('build_ok'), 'center': s.get('center'), 'ground_y': s.get('ground_y'),
            'terrain_height_range': s.get('terrain_height_range'), 'plan_bounds': s.get('plan_bounds'),
            'has_wall': s.get('has_wall'), 'wall_features': s.get('feature_count'),
            'envelope_chunks': e.get('chunks'), 'envelope_snapshot_voxels': e.get('snapshot_voxels'),
            'envelope_declined': s.get('envelope_declined'),
            'worst_alignment_chunks': worst[0], 'worst_alignment_shift': worst[1],
            'changed_nodes': ch.get('nodes'), 'outside_nonliquid': out.get('non_liquid'),
            'outside_liquid_reflow': out.get('liquid_reflow'),
            'outside_examples': out.get('examples'), 'stage_overhang': s.get('stage_overhang'),
            'stage_overrun_nodes': s.get('stage_overrun_nodes'), 'interval_outside_nodes': s.get('interval_outside_nodes'),
            'stage_reach_actual': stage_reach_actual(s),
            'within_max_rect': s.get('within_max_rect'), 'within_window': s.get('within_window'),
            'snapshot_ignore_blocks': s.get('snapshot_ignore_blocks'),
            'changed_bbox': ch.get('bbox'), 'changed_bbox_relative_to_center': ch.get('relative_to_center'),
            'read_side_requests': (s.get('read_side') or {}).get('total'),
            'read_side_outside': (s.get('read_side') or {}).get('outside_read'),
            'reads_beyond_slack': s.get('reads_beyond_slack'),
            'inspection_volume_inside_urban_read': inspection_check(s),
            'reported_vs_envelope_uncontained': [r['label'] for r in s.get('reported_vs_envelope') or [] if not r['contained']],
            'pipeline': s.get('pipeline'),
            'intervals': [{k: v for k, v in iv.items() if k in (
                'label', 'allowed', 'total', 'in_allowed', 'in_other_box', 'outside', 'reflow', 'max_reach',
                'max_reach_base', 'bbox', 'other_examples', 'outside_examples')} for iv in s.get('intervals') or []],
            'stages': {k: v['box'] for k, v in (e.get('stages') or {}).items()},
        })
    # per-stage maxima
    ok = [d for d in digest if d.get('status') not in (None, 'no_site')]
    reach = {}
    over = {}
    for d in ok:
        for stage, r in (d.get('stage_reach_actual') or {}).items():
            reach[stage] = max(reach.get(stage, 0), r)
        for stage, r in (d.get('stage_overhang') or {}).items():
            over[stage] = max(over.get(stage, 0), r)
    print()
    print('Samples evaluated: %d  contained: %d  no_site: %d' % (
        len(ok), sum(1 for d in ok if d['status'] == 'contained'), len(digest) - len(ok)))
    print('Max chunks (observed alignment): %s   worst alignment: %s' % (
        max((d['envelope_chunks'] or 0 for d in ok), default=None),
        max((d['worst_alignment_chunks'] or 0 for d in ok), default=None)))
    print('Per stage, max over samples: actual reach beyond plan.bounds | box overhang (stage boxes)')
    for stage in sorted(set(reach) | set(over)):
        print('  %-28s actual %3s | box %3s' % (stage, reach.get(stage), over.get(stage)))
    if args.digest:
        args.digest.write_text(json.dumps(digest, indent=1))
        print('digest:', args.digest)


if __name__ == '__main__':
    main()
