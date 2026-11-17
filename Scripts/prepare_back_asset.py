#!/usr/bin/env python3
"""Turn the photographed back of the Pipa into the asset used by the browse view.

pipa_B.jpg was shot against a pale cloth. The wood is far redder than the
cloth, so a channel-difference threshold separates it. The two largest
components are the body and the head/peg assembly; a vertical closing joins
the pale neck between them. One small cloth patch between the pegs is then
removed with a stricter colour test.

Output is aligned to the front asset: 506 x 1557 with a 3 pt margin, so both
faces share the Pipa3DGeometry reference frame (nut y 268, bridge y 1441).
"""

from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "pipa_B.jpg"
OUT_DIR = ROOT / "App/Assets.xcassets/PipaInstrumentBack.imageset"
OUT = OUT_DIR / "pipa_back.png"

WIDTH, HEIGHT, MARGIN = 506, 1557, 3
TARGET_H = HEIGHT - 2 * MARGIN

src = Image.open(SOURCE).convert("RGB")
rgb = np.array(src).astype(np.int16)
r_g = rgb[..., 0] - rgb[..., 1]
r_b = rgb[..., 0] - rgb[..., 2]

# Wood is red; the cloth is nearly neutral. Close small holes before labelling.
wood = (r_g > 20) & (r_b > 30) & (rgb[..., 0] < 225)
wood = ndi.binary_closing(wood, structure=np.ones((5, 5)), iterations=2)
wood = ndi.binary_fill_holes(wood)
labels, count = ndi.label(wood)
sizes = ndi.sum(wood, labels, range(1, count + 1))
largest = 1 + np.argsort(sizes)[::-1][:2]
mask = np.isin(labels, largest)

# The pale bone nut between head and body did not pass the colour test.
# A vertical-only closing bridges that gap without eating the peg silhouette.
mask = ndi.binary_closing(mask, structure=np.ones((90, 1)), iterations=1)
mask = ndi.binary_fill_holes(mask)
labels, count = ndi.label(mask)
sizes = ndi.sum(mask, labels, range(1, count + 1))
mask = labels == (1 + int(np.argmax(sizes)))

# Cloth showing between the four pegs became an enclosed hole after filling.
# Those patches are large, neutral-coloured and high on the instrument; the
# pale neck and the white reflection at the tail are smaller or lower, so they
# survive.
pale = mask & ~((r_g > 20) & (r_b > 30))
patches, count = ndi.label(pale)
sizes = ndi.sum(pale, patches, range(1, count + 1))
for i in range(count):
    if sizes[i] < 800:
        continue
    ys_i, xs_i = np.where(patches == i + 1)
    if ys_i.max() >= 500 or (rgb[ys_i, xs_i, 0] - rgb[ys_i, xs_i, 1]).mean() >= 20:
        continue
    mask[patches == i + 1] = False

# Removing the cloth also removed the bridge between head and body.
# The neck is a narrow wooden shaft at x ~= 485-497 in the source; restore
# just that strip instead of a morphological closing, which would also
# seal the peg box again.
mask[330:450, 484:497] = True

ys, xs = np.where(mask)
crop = np.array(src)[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
alpha = (mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1] * 255).astype(np.uint8)

scale = TARGET_H / crop.shape[0]
new_w = max(1, round(crop.shape[1] * scale))
crop_img = Image.fromarray(np.dstack([crop, alpha]), "RGBA")
crop_img = crop_img.resize((new_w, TARGET_H), Image.LANCZOS)

canvas = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
canvas.paste(crop_img, ((WIDTH - new_w) // 2, MARGIN), crop_img)

OUT_DIR.mkdir(parents=True, exist_ok=True)
canvas.save(OUT, optimize=True)
(OUT_DIR / "Contents.json").write_text(
    '{"images": [{"filename": "pipa_back.png", "idiom": "universal"}], '
    '"info": {"author": "xcode", "version": 1}}\n'
)

final = np.array(canvas)
fy, fx = np.where(final[..., 3] > 128)
print(f"source {src.size} -> {OUT.name} {canvas.size}, "
      f"alpha bbox x {fx.min()}-{fx.max()} y {fy.min()}-{fy.max()}")
