# Bust from the user's front render (bald man, planar head, thick neck, bust cut in a V), 2026-11-06.
# Proportions from the photo, as fractions of top-to-chin (640 px = 188 mm):
#   eyes 0.48, brow 0.44, nose base 0.67, mouth 0.78, ears 0.45-0.71;
#   cranium width 0.65, face under the ears 0.61, chin 0.23;
#   shoulder top at 1.15 below the top (width 0.91), V tip at 1.68 (width 0.31).
# Run: PYTHONPATH=<skill folder> python3 prassitele_bust.py [port] [stage] [quads close blend]   stage: skull | soft | bust | remesh | eyes
import sys  # prassitele_mcp comes from PYTHONPATH, or from this file's folder when run in place
from prassitele_mcp import call
P = int(sys.argv[1]) if len(sys.argv) > 1 else 48765
stage = sys.argv[2] if len(sys.argv) > 2 else 'skull'
def run(n, a):
    r, e, _ = call(P, n, a)
    if e: raise SystemExit(f'{n}: {e}')
    return r
def prim(kind, name, c, s, rot=(0, 0, 0), q=None):
    return run('add_primitive', {'kind': kind, 'quads': q or (216 if kind == 'box' else 600), 'center_mm': list(c), 'size_mm': list(s), 'rotation_deg': list(rot), 'name': name})
def box(*a, **k): return prim('box', *a, **k)
def sph(*a, **k): return prim('sphere', *a, **k)
def cyl(*a, **k): return prim('cylinder', *a, **k)
def mirror(f, name, c, s, rot=(0, 0, 0)):
    # The part on +X and its mirror image, in one SubTool.
    kind = {box: 'box', sph: 'sphere', cyl: 'cylinder'}[f]
    return run('add_primitive', {'kind': kind, 'quads': 216 if kind == 'box' else 600, 'center_mm': list(c), 'size_mm': list(s), 'rotation_deg': list(rot), 'name': name, 'mirror': True})
if stage == 'skull':
    for t in run('get_scene', {})['subtools']:
        run('select_subtool', {'id': t['id']}); run('transform_subtool', {'translate_mm': [0, -700, -500]})
    # Cranium 0.65 of the height wide (124 mm), widest at the temples.
    sph('cranio', (0, 30, 8), (124, 124, 146), (-8, 0, 0), q=1500)
    box('ossa nasali', (0, -2, 79), (13, 26, 8), (-28, 0, 0))
    box('mascella', (0, -36, 50), (58, 42, 58))
    # Strong, square cheekbones.
    mirror(box, 'zigomo', (46, -15, 50), (22, 20, 24), (0, 25, 0))
    mirror(box, 'bordo orbita', (45, 1, 58), (10, 32, 12), (0, 0, -8))
    mirror(box, 'arcata zig', (56, -11, 22), (8, 9, 44))
    # Broad, square jaw.
    mirror(box, 'mandibola', (31, -72, 40), (14, 24, 64), (24, -25, 0))
    mirror(box, 'ramo', (47, -40, 4), (12, 60, 26), (-12, 0, 0))
    mirror(box, 'arcata', (22, 20, 70), (44, 13, 18), (0, 16, 0))  # +Y turns the outer end back
    box('glabella', (0, 17, 74), (16, 14, 12))
    # Wide, square chin.
    box('mento', (0, -78, 70), (40, 30, 26))
if stage == 'soft':
    sph('naso', (0, -19, 89), (20, 30, 22), (-18, 0, 0))
    sph('bocca', (0, -54, 80), (52, 36, 22))
    sph('cuscinetto mento', (0, -80, 86), (38, 24, 14))
    mirror(sph, 'temporale', (51, 22, 20), (10, 54, 56))
    mirror(sph, 'massetere', (50, -46, 24), (16, 50, 32), (-15, 0, 0))
    mirror(sph, 'guancia', (40, -22, 62), (24, 24, 22))
    # Ears 0.45-0.71: y 8 to -40.
    mirror(box, 'orecchio', (62, -15, -10), (9, 52, 28), (-15, 15, 0))
if stage == 'bust':
    # Thick neck going up into the base of the skull, down into the chest.
    cyl('collo', (0, -115, -20), (106, 170, 96), (12, 0, 0), q=600)
    # Trapezius sloping from the neck to the shoulders.
    mirror(box, 'trapezio', (45, -118, -25), (70, 26, 80), (0, 0, -24))
    # Chest: shoulder top at y -126, 171 wide; sides closing to a V tip at y -224, 58 wide.
    mirror(box, 'petto', (40, -165, -5), (80, 90, 105), (0, 0, 30))
    box('sterno', (0, -163, 0), (86, 86, 100), (0, 0, 45))
if stage == 'remesh':
    ids = [t['id'] for t in run('get_scene', {})['subtools'] if t['bounds']['center_mm'][1] > -400]
    run('select_subtool', {'id': ids[0]}); run('merge_subtools', {'ids': ids})
    # Defaults are for a bust; a head alone takes about 17000 9 8.
    q, c, b = (sys.argv[3:6] + ['48000', '13', '10'][len(sys.argv[3:6]):])
    print(run('remesh', {'target_quads': int(q), 'close_mm': float(c), 'blend_mm': float(b)}))
if stage == 'eyes':
    head = run('get_scene', {})['active_subtool']
    run('move_region', {'center_mm': [28, 6, 70], 'radius_mm': 17, 'delta_mm': [0, 0, -10]})
    mirror(sph, 'occhio', (28, 5, 57), (24, 24, 24))
    run('select_subtool', {'id': head})
