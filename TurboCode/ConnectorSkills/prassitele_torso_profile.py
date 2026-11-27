# Midline profile of the active SubTool (back and front z, width) every 60 mm in y. Run: PYTHONPATH=<skill folder> python3 prassitele_torso_profile.py <port>
import sys  # prassitele_mcp comes from PYTHONPATH, or from this file's folder when run in place
from prassitele_mcp import call
P = int(sys.argv[1]); OX = float(sys.argv[2]) if len(sys.argv) > 2 else 0
ys = [60, 0, -60, -120, -180, -240, -300, -360, -420, -480, -540, -600, -660]
r, e, _ = call(P, 'measure_sections', {'axis': 'y', 'at_mm': ys})
if e: raise SystemExit(e)
print(' y     back  front  width')
for s in r['sections']:
    b, f = s['z_on_midline_mm'] or [None, None]; x = s['x_range_mm']
    print(f"{s['y_mm']:5.0f} {b:7.1f} {f:6.1f} {x[1]-x[0]:6.0f}")
