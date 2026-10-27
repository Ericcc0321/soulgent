# Stitches burst-captured live frames of the panel into one contact sheet: python3 -I tools/dev/contact_sheet.py <folder> <frame,frame,...> <out.png> [x0,y0,x1,y1]
# Frame files are named fNNN.png (as produced by a --capture-live burst); the crop box is in source-image pixels.
import sys
from PIL import Image
d, frames, out = sys.argv[1], sys.argv[2].split(','), sys.argv[3]
box = tuple(int(v) for v in sys.argv[4].split(',')) if len(sys.argv) > 4 else None
ims = [Image.open(f'{d}/f{int(n):03d}.png').convert('RGB') for n in frames]
if box: ims = [im.crop(box) for im in ims]
w, h = ims[0].size; s = 0.5; cols = 2; rows = (len(ims) + 1) // 2
sheet = Image.new('RGB', (int(w * s) * cols, int(h * s) * rows), 'white')
for i, im in enumerate(ims):
    sheet.paste(im.resize((int(w * s), int(h * s))), ((i % cols) * int(w * s), (i // cols) * int(h * s)))
sheet.save(out)
