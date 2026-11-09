---
name: prassitele-sculpting
description: "Block out a head (or any form made of parts) in the Prassitele app through its MCP tools: a skull of boxes, soft masses over it, one fused remesh, proportions from a photo. Use when asked to block out, build or proportion a head, a bust or a figure in Prassitele, or to try its agent tools."
---

# Blocking out in Prassitele

The job is the blockout: parts placed with numbers, fused by one remesh, brought to the proportions of a photo if there is one. The sculptor refines by hand afterwards. Don't sculpt details.

If the tools don't answer, ask the user to turn on **Agent > Agent Server (MCP)**.

Axes, in mm: +X is the viewer's right in the front view, +Y up, +Z toward the viewer; a face looks toward +Z. Symmetry is around x = 0.

## The method

1. **Skull** of boxes, cranium a sphere.
2. **Soft masses** (spheres) in front of the bone, as flesh lies over it.
3. **Ears and neck** (and a bust, if asked).
4. **Merge and remesh** with `close_mm` and `blend_mm`: one closed surface.
5. **Eyes** as separate spheres in dug sockets.
6. **Proportions** from the photo, with broad moves, then stop.

**Every Prassitele tool is called through the `connector` tool**: `operation` `call`, `toolName` the name used here (`add_primitive`, `remesh`, ...), `argumentsJSON` its arguments. Call `list_tools` once first to read the exact argument names.

**Build the parts one `add_primitive` call per row of the tables below.** There is no script and no shell on the user's Mac here. Work one stage at a time (skull, then soft masses, ...) and look between stages with `observe` and `measure_sections`. Look at `right` and `three_quarter` after each stage: they show the rhythm of the masses better than the front. When a part is wrong, fix that part instead of starting over.

**Fix proportions before the merge, on the parts.** Every part is its own SubTool until `merge_subtools`, and a mirrored pair (both cheekbones, both rami) is one SubTool centered on x = 0. So `select_subtool` and `transform_subtool` change a pair at once and keep it symmetric:

- `scale` [1.1, 1, 1] widens the pair: the two parts move apart and grow. The default pivot is the center of the SubTool, x = 0 for a pair.
- `translate_mm` only in Y and Z. A translation in X moves both parts to the same side and breaks the symmetry.
- No `rotate_deg` on a pair, except around X: the two halves would turn the same way. To turn the parts, remove the SubTool with `delete_subtool` and add it again with the new rotation.

After the merge the parts are gone: proportions change only with soft moves (step 6).

Start from a fresh scene. Move anything already there out of the way with `transform_subtool` and tell the user.

## 1. Skull

For a man about 188 mm from the top of the head to the chin, eyes at y = 5. Rows marked **mirror** are one `add_primitive` call with `mirror: true`: the part as given on the +X side plus its mirror image, in one SubTool.

| Part | kind | Center | Size | Rotation | |
|---|---|---|---|---|---|
| cranium | sphere, 1500 quads | 0, 30, 8 | 130, 124, 146 | -8, 0, 0 | |
| nasal bones | box | 0, -2, 79 | 13, 26, 8 | -28, 0, 0 | |
| maxilla | box | 0, -36, 50 | 58, 42, 58 | | |
| cheekbone | box | 46, -15, 50 | 22, 20, 24 | 0, 25, 0 | mirror |
| outer orbit rim | box | 45, 1, 58 | 10, 32, 12 | 0, 0, -8 | mirror |
| zygomatic arch | box | 56, -11, 22 | 8, 9, 44 | | mirror |
| body of the mandible | box | 30, -72, 40 | 13, 22, 64 | 24, -27, 0 | mirror |
| ramus | box | 46, -38, 4 | 11, 58, 26 | -12, 0, 0 | mirror |
| brow | box | 22, 20, 70 | 44, 13, 18 | 0, 16, 0 | mirror |
| glabella | box | 0, 17, 74 | 16, 14, 12 | | |
| chin | box | 0, -78, 70 | 36, 30, 26 | | |

- On the +X side a positive Y rotation turns the outer end of a part back. The brow at -16 came forward and read as a visor in profile.
- Check the profile: forehead, brow, nasal bones, the front of the maxilla almost vertical, the chin under it, the mandible rising to the ramus, the arch reaching the ear.
- Check the front: orbits about 30 mm tall between brow and cheekbone, the chin reaching up to the maxilla.
- Check from the top: the cranium narrower in front than behind; if not, `scale_region` at its front, about 0.86 in X.

**Variations.** A woman: everything about 7 % smaller, forehead upright and round, no brow boxes (even thin ones read as a plank), high cheekbones kept wide, narrow mandible with short rami, small chin, cranium moved back so the forehead meets the brow line. A heavy man: chin and mandible wider (chin 40 wide), rami and masseters thicker.

## 2. Soft masses

Spheres of 600 quads, 5 to 12 mm **in front of** the bone blocks. A mouth inside the maxilla left maxilla and chin showing as a T.

| Mass | Center | Size | Rotation | |
|---|---|---|---|---|
| nose | 0, -19, 89 | 18, 28, 22 | -18, 0, 0 | |
| mouth barrel | 0, -54, 80 | 52, 36, 22 | | |
| chin pad | 0, -80, 86 | 34, 24, 14 | | |
| temporalis | 51, 22, 20 | 10, 54, 56 | | mirror |
| masseter | 49, -45, 24 | 14, 48, 30 | -15, 0, 0 | mirror |
| cheek, high on the cheekbone | 40, -22, 62 | 24, 24, 22 | | mirror |

- One cheek mass per side; two stay two bumps. A lean face has no low cheek mass; a full face (woman, child) takes one longer mass running down.
- Keep the temporalis inside the curve of the cranium, or it reads as headphones.

## 3. Ears, neck, bust

- Ears: a box 9 × 58 × 28 at x = 61 (mirror), from the brow to the base of the nose, rotation -15, 15, 0. Thicker or more flared, they read as headphones.
- Neck: a cylinder about 96 × 130 × 90, center 0, -95, -25, rotation 14, 0, 0. Its top goes up into the base of the skull at the back; in front it stays behind and below the mandible, or the fusion fills the corner under the jaw. A neck that stops short of the skull leaves a gap.
- A bust: trapezius boxes from the neck to the shoulders, chest boxes, and a box turned 45 degrees around Z for a V at the bottom.

## 4. Merge and remesh

`merge_subtools` with every part, then `remesh`:

- A head: `target_quads` 16000 to 18000, `close_mm` 9, `blend_mm` 8.
- A bust is about twice the volume: 48000 quads. At 24000 the voxels were too coarse and the face stayed in blocks.
- `close_mm` fills gaps narrower than about twice its value. If the side of the face still shows a hollow between cheekbone, masseter and ramus, go back with `restore_checkpoint` and remesh at 12 to 13. At 6 a small head kept holes.
- `blend_mm` rounds the joins. 10 gives a softer face; 20 melted the orbits and the nose.
- `flow_aligned: false` in the result means the surface still had holes.

## 5. Eyes

After the fusion: dig each socket with `move_region` (center 28, 6, 70, radius 17, delta 0, 0, -10, symmetric), then add the eyes with `add_primitive` (sphere 24 mm at 28, 5, 57, `mirror: true`). In the merge the closing would fill them. Eyes that stand out of the socket in profile read as ping-pong balls: move them back.

## 6. Proportions from a photo

From a front photo, take the height from the top of the head to the chin, then as fractions of it: the eye line, brow, base of the nose, mouth, top and bottom of the ears; widths of the cranium, at the cheekbones, below the ears, at the angle of the jaw, at the chin. Read them from rows of pixels if you can process the image (convert it with `sips -s format bmp`), otherwise from the picture.

Then cut the model with `measure_sections` (axis y) at the same fractions and fix the differences with broad `move_region` (radius 20 to 40 mm) and `scale_region` moves. To narrow or shorten the whole head, use `transform_subtool`.

- At the height of the ears a section measures the ears; at the height of the jaw and chin it measures the neck. Judge those in the front view.
- A turned head skews the widths: use such a photo for the rhythm, not the millimetres. A front photo says nothing about depth: leave the profile to the skull, or use a profile photo.
- A part that sticks out after the fusion (a brow end, the arch) is moved back with one `move_region` centered on it: find where it is with `measure_sections`, since a move centered 20 mm away does nothing. `smooth_region` barely changes forms this size.
- A last remesh with `close_mm` 4 and `blend_mm` 5 heals small folds left by the moves.

Stop there and tell the user what is left: the sculptor takes it from the blockout.

## Safety

- `merge_subtools` and `remesh` clear the history but save a checkpoint first: go back with `restore_checkpoint`. Other changes go back with `undo`, per SubTool.
- A primitive is removed with `delete_subtool`, not `undo`. You can delete only what you made.
- Never restore a checkpoint over a SubTool the user has been sculpting on.
- If a tool answers that the user pressed Stop, stop and wait.
