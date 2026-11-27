# Torso blockout of 2026-11-27, from primitives; fused with: remesh 110000 30 16 (about 52000 quads).
# Male torso blockout, about 1.80 m: sternal notch at y 0, nipples -170, navel -400, crotch -630.
# Run: PYTHONPATH=<skill folder> python3 prassitele_torso.py <port> <stage> [x offset mm] [quads close blend]   stage: bone | soft | remesh | clear
import sys  # prassitele_mcp comes from PYTHONPATH, or from this file's folder when run in place
from prassitele_mcp import call
P = int(sys.argv[1]); stage = sys.argv[2]; OX = float(sys.argv[3]) if len(sys.argv) > 3 else 0
def run(n, a):
    r, e, _ = call(P, n, a)
    if e: raise SystemExit(f'{n}: {e}')
    return r
def prim(kind, name, c, s, rot=(0, 0, 0), q=None, m=False):
    a = {'kind': kind, 'quads': q or (216 if kind == 'box' else 600), 'center_mm': [c[0] + OX, c[1], c[2]],
         'size_mm': list(s), 'rotation_deg': list(rot), 'name': 'torso ' + name}
    if m: a['mirror'] = True; a['center_mm'][0] = c[0]  # mirror needs x about 0; shifted after
    return run('add_primitive', a)
TAG = 'torso '
def parts(): return [t for t in run('get_scene', {})['subtools'] if t['name'].startswith(TAG)]
def mir(kind, name, c, s, rot=(0, 0, 0)):
    prim(kind, name, c, s, rot, m=True)
    if OX: run('transform_subtool', {'translate_mm': [OX, 0, 0]})
if stage == 'clear':
    for t in parts():
        if '[before' in t['name'] or t['bounds']['center_mm'][1] < -2000: continue
        r, e, _ = call(P, 'delete_subtool', {'id': t['id']})
        if e:  # the only visible SubTool cannot be deleted: move it out of the way
            run('select_subtool', {'id': t['id']}); run('transform_subtool', {'translate_mm': [0, -3000, 0]})
if stage == 'bone':
    prim('sphere', 'ribcage', (0, -170, -16), (290, 390, 215), (-18, 0, 0), q=1500)
    prim('sphere', 'pelvis', (0, -565, -12), (300, 190, 205), (20, 0, 0))
    prim('sphere', 'abdomen', (0, -410, 10), (265, 280, 180))
    prim('sphere', 'shoulder girdle', (0, -35, -20), (320, 110, 165))
    prim('cylinder', 'neck', (0, 65, -10), (130, 150, 120), (22, 0, 0))
    mir('box', 'clavicle', (95, -2, 22), (175, 20, 24), (0, 18, 8))
    mir('sphere', 'scapula', (80, -110, -100), (105, 150, 26), (15, -28, 0))
    mir('sphere', 'shoulder', (180, -25, -15), (80, 85, 85))
    mir('cylinder', 'upper arm', (258, -105, -15), (85, 200, 92), (0, 0, 45))  # 45 degrees out from the side
    mir('cylinder', 'thigh', (92, -700, 10), (155, 190, 165), (0, 0, 4))
if stage == 'soft':
    mir('sphere', 'pectoral', (68, -90, 88), (155, 112, 38), (-6, 24, 14))
    mir('sphere', 'deltoid', (205, -50, -5), (95, 155, 118), (0, 0, 35))
    mir('sphere', 'trapezius', (58, 30, -45), (125, 50, 110), (20, 0, -25))
    mir('sphere', 'latissimus', (118, -225, -38), (70, 270, 160), (-12, 0, -12))
    prim('sphere', 'rectus', (0, -370, 78), (130, 310, 50), (-4, 0, 0))
    mir('sphere', 'oblique', (108, -490, 8), (62, 120, 140))
    mir('sphere', 'erector', (34, -270, -84), (62, 220, 46), (-15, 0, 0))
    mir('sphere', 'lumbar erector', (36, -450, -74), (76, 210, 60), (22, 0, 0))
    prim('sphere', 'lower belly', (0, -520, 72), (190, 130, 60))
    mir('sphere', 'gluteus', (80, -620, -62), (150, 170, 110), (-10, 0, 0))
if stage == 'remesh':
    ids = [t['id'] for t in parts() if '[before' not in t['name'] and t['bounds']['center_mm'][1] > -2000]
    run('select_subtool', {'id': ids[0]}); run('merge_subtools', {'ids': ids})
    print(run('remesh', {'target_quads': int(sys.argv[4]) if len(sys.argv) > 4 else 110000,
                         'close_mm': float(sys.argv[5]) if len(sys.argv) > 5 else 30,
                         'blend_mm': float(sys.argv[6]) if len(sys.argv) > 6 else 16}))
