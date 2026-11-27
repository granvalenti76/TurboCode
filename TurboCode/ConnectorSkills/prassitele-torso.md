---
name: prassitele-torso
description: "Block out a human torso in the Prassitele app through its MCP tools: ribcage, abdomen and pelvis as volumes, muscle masses over them, arm and thigh stumps, one fused remesh. Use when asked to block out, build or proportion a torso, a trunk or the body of a figure in Prassitele. For a head or a bust use prassitele-sculpting."
---

# Torso blockout in Prassitele

The job is the blockout: parts placed with numbers, fused by one remesh. The sculptor refines by hand afterwards. Don't sculpt details or anatomy.

If the tools don't answer, ask the user to turn on **Agent > Agent Server (MCP)**.

Axes, in mm: +X is the viewer's right in the front view, +Y up, +Z toward the viewer; the chest looks toward +Z. Symmetry is around x = 0.

## The method

1. **Bone volumes**: ribcage, abdomen, pelvis, shoulder girdle, neck, clavicles, scapulae, stumps of arms and thighs.
2. **Muscle masses** over them, a few mm proud of the bone.
3. **Ask before the merge.** Show the blockout and ask the user whether they want the merge and remesh, or whether the separate parts are enough. Parts can still be moved one by one; after the remesh they are gone. Merge only on a yes.
4. **Merge and remesh** with `close_mm` and `blend_mm`: one closed surface.
5. **Look** at front, three quarter, right and back; change numbers and rebuild.

**Build with the bundled scripts**, not one tool call at a time. They are in `{{SKILL_DIR}}` and call the Prassitele agent server on this Mac directly, so one Bash command runs a whole stage. To change numbers, copy `prassitele_torso.py` into `$TMPDIR`, edit the copy and run that; run it unchanged in place otherwise. `PYTHONPATH` lets a copy find `prassitele_mcp.py`:

```
PYTHONPATH="{{SKILL_DIR}}" python3 "{{SKILL_DIR}}/prassitele_torso.py" 48765 bone 0
PYTHONPATH="{{SKILL_DIR}}" python3 "{{SKILL_DIR}}/prassitele_torso.py" 48765 soft 0
PYTHONPATH="{{SKILL_DIR}}" python3 "{{SKILL_DIR}}/prassitele_torso.py" 48765 remesh 0 110000 30 16
PYTHONPATH="{{SKILL_DIR}}" python3 "{{SKILL_DIR}}/prassitele_torso.py" 48765 clear          # deletes the torso parts, to rebuild
```

The `0` is the x offset in mm and is **never left out**: the remesh numbers come after it, so `remesh 110000 30 16` reads 110000 as the offset and asks for 30 quads, which fuses the torso into a lump of about 20. Use the same offset for every stage.

The `connector` tool reaches the same app: use it for `observe` and for single calls between stages.

Every part is named `torso …`, so `clear` and `remesh` touch only the torso. `clear` deletes the parts or the fused torso; if that is the only visible SubTool it moves it 3000 mm down instead, and later stages ignore anything that far down. An offset other than 0 (mm) builds it beside whatever is already in the scene: the user's work stays where it is. Mirrored parts are one SubTool built on x = 0 and then moved, so they stay symmetric.

Look with `observe` (`center_mm` on the torso, `extent_mm` about 1050) after `bone`, after `soft` and after `remesh`. Look at `three_quarter`, `right` and `back`, not only the front.

## Proportions

A man of about 1.80 m, a head of about 230 mm: sternal notch at y 0, nipples at -170 (one head below the chin), navel at -400, crotch at -630. Shoulders across the deltoids about 500 mm, waist about 270, hips about 300.

## 1. Bone volumes

| Part | kind | Center | Size | Rotation | |
|---|---|---|---|---|---|
| ribcage | sphere, 1500 quads | 0, -170, -16 | 290, 390, 215 | -18, 0, 0 | |
| abdomen | sphere | 0, -410, 10 | 265, 280, 180 | | |
| pelvis | sphere | 0, -565, -12 | 300, 190, 205 | 20, 0, 0 | |
| shoulder girdle | sphere | 0, -35, -20 | 320, 110, 165 | | |
| neck | cylinder | 0, 65, -10 | 130, 150, 120 | 22, 0, 0 | |
| clavicle | box | 95, -2, 22 | 175, 20, 24 | 0, 18, 8 | mirror |
| scapula | sphere | 80, -110, -100 | 105, 150, 26 | 15, -28, 0 | mirror |
| head of the humerus | sphere | 180, -25, -15 | 80, 85, 85 | | mirror |
| upper arm stump | cylinder | 258, -105, -15 | 85, 200, 92 | 0, 0, 45 | mirror |
| thigh stump | cylinder | 92, -700, 10 | 155, 190, 165 | 0, 0, 4 | mirror |

## 2. Muscle masses

| Mass | kind | Center | Size | Rotation | |
|---|---|---|---|---|---|
| pectoral | sphere | 68, -90, 88 | 155, 112, 38 | -6, 24, 14 | mirror |
| deltoid | sphere | 205, -50, -5 | 95, 155, 118 | 0, 0, 35 | mirror |
| trapezius | sphere | 58, 30, -45 | 125, 50, 110 | 20, 0, -25 | mirror |
| latissimus | sphere | 118, -225, -38 | 70, 270, 160 | -12, 0, -12 | mirror |
| rectus abdominis | sphere | 0, -370, 78 | 130, 310, 50 | -4, 0, 0 | |
| lower belly | sphere | 0, -520, 72 | 190, 130, 60 | | |
| external oblique | sphere | 108, -490, 8 | 62, 120, 140 | | mirror |
| thoracic erector | sphere | 34, -270, -84 | 62, 220, 46 | -15, 0, 0 | mirror |
| lumbar erector | sphere | 36, -450, -74 | 76, 210, 60 | 22, 0, 0 | mirror |
| gluteus | sphere | 80, -620, -62 | 150, 170, 110 | -10, 0, 0 | mirror |

Rotations: on the +X side, a positive Y rotation turns the outer end back; a positive Z rotation raises the outer end; a negative Z rotation tilts the top of a long part outward (the V of the lats). A positive X rotation tilts the top of a part forward (+Z), a negative one back.

## Rhythm: the S of the spine

A torso built straight reads as a barrel on legs. The sculptor's first complaint was no rhythm: in profile the back was a straight line, -89 to -105 mm from the neck to the sacrum. The masses alternate:

- **Neck** leans forward (X +22).
- **Ribcage** leans back (X -18) and sits back (z -16): the upper back rounds out behind the scapulae. Leaning back also brings its lower front forward: keep it shallow (215) and let the pectorals give the chest its depth, or the front under the pectorals reads as a pot belly.
- **Abdomen** sits forward (z +10) and shallower: the lumbar curve goes in.
- **Pelvis** tips forward (X +20): the sacrum and the glutes come back out.
- **Erectors** are two parts that follow the curve: thoracic leaning back (X -15), lumbar leaning forward (X +22). One long ellipsoid stays straight.
- Scapulae, lats and trapezius turn with the ribcage under them.

**Measure it**, don't judge it by eye: after the remesh run `PYTHONPATH="{{SKILL_DIR}}" python3 "{{SKILL_DIR}}/prassitele_torso_profile.py" 48765`. It prints the back and front of the midline every 60 mm. The recipe gives:

| y | back | front |
|---|---|---|
| 60 (neck) | -76 | 52 |
| -120 (upper back, chest) | -134 | 119 |
| -240 (bottom of the ribcage) | -106 | 102 |
| -360 (waist) | -74 | 102 |
| -540 (sacrum) | -111 | 100 |

The back must go out, in and out again: at least 40 mm between the upper back and the waist, and 30 mm between the waist and the sacrum. In front the chest (y -120) must be the deepest point, at least 10 mm ahead of y -240.

`prassitele_torso_profile.py` measures the **active** SubTool at x = 0 (offset or not, the midline of a mirrored torso is where its parts are). Its width column includes the arm stumps from y 0 to -180, so it cannot measure the shoulder V; below -300 it is the waist (about 250) and the hips (about 300). With the arms out, the side view shows the curve; still trust the numbers over the eye.

## Arms out at 45 degrees

The arm stumps go out 45 degrees from the sides (rotation Z +45 on the +X side), not hanging down. Hanging arms fuse with the ribcage and the lats in the remesh (`close_mm` 30 fills the armpit), and they hide the profile. The deltoid turns with the arm (Z +35). Not a T-pose: the armpit stays open but the shoulder keeps its shape.

## What went wrong on the way (2026-11-27)

- **Boxes at the surface read as planks or underwear.** A box for the upper chest left a rectangle across the chest; a box pelvis read as briefs; a box rectus as a board. Keep boxes inside (clavicles, scapulae) or thin; the visible volumes are spheres.
- **Pectorals as full spheres read as breasts.** They are flat (44 mm deep), high, turned toward the armpit, and barely in front of the ribcage.
- **Obliques too big make love handles**, and glutes as balls stick far out in profile. Keep them small and forward, overlapping the volumes under them.
- **Scapulae as boxes** left a sharp step at their lower edge once the ribcage leaned back: flat spheres instead.
- **The waist pinches** when the ribcage and pelvis are joined only by small masses: the abdomen is its own large sphere.

## 3. Merge and remesh

Only after the user said yes to it (step 3 of the method). If they keep the blockout, stop here and tell them what is left.

The torso is about 4.5 times the volume of a head. Request 110000 quads (about 52000 come out), `close_mm` 30, `blend_mm` 16. The arms out at 45 degrees widen the bounding box and the voxels grow with it: at 90000 the surface kept holes.

- At 60000 requested and `close_mm` 15 the parts stayed separate, with gaps at the waist.
- At 24 and 28 the same recipe sometimes came out with `flow_aligned: false` (holes), and a slimmer waist needed 30.
- `flow_aligned: false` in the result means the surface still had holes: `clear`, rebuild, and remesh with `close_mm` a few mm larger.

## Checks

- **Front**: shoulders the widest line, a V from the armpits to the waist, the pelvis a little wider than the waist, chest masses flat.
- **Right**: the S of the back and the chest ahead of the belly (see Rhythm), the glutes not sticking out more than about 50 mm past the back.
- **Back**: scapulae and erectors are soft ridges, not plates; trapezius sloping from the neck to the shoulders.

Stop there and tell the user what is left: cut stumps, flanks still a little lumpy, lats and erectors still reading as separate cords in the back, pectorals as round lenses, round masses where the sculptor will want planes. The sculptor takes it from the blockout.

## Safety

- `merge_subtools` and `remesh` clear the history but save a checkpoint first: go back with `restore_checkpoint`.
- A primitive is removed with `delete_subtool`, not `undo`. You can delete only what you made.
- Never move, delete or restore over the user's SubTools.
- If a tool answers that the user pressed Stop, stop and wait.
