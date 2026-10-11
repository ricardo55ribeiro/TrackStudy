"""Rasterize our simple vector icon using Pillow; no system renderer needed."""
from pathlib import Path
from xml.etree import ElementTree
from PIL import Image, ImageDraw

root = Path(__file__).resolve().parent.parent
svg = ElementTree.parse(root / 'assets/app_icon.svg').getroot()
scale = 4
image = Image.new('RGBA', (256 * scale, 256 * scale))
draw = ImageDraw.Draw(image)
def render(element, inherited_fill=None):
    fill = element.get('fill', inherited_fill)
    if element.tag.endswith('rect'):
        x, y, w, h, radius = [int(element.get(k, '0')) * scale for k in ('x', 'y', 'width', 'height', 'rx')]
        draw.rounded_rectangle((x, y, x+w, y+h), radius=radius, fill=fill)
    for child in element:
        render(child, fill)
render(svg)
for top in (68, 118, 168):
    for y in range(top, top+20, 6):
        draw.line((168*scale, y*scale, 168*scale, min(y+3, top+20)*scale), fill='#e6efff', width=3*scale)
image = image.resize((256, 256), Image.Resampling.LANCZOS)
image.save(root / 'windows/runner/resources/app_icon.ico',
           sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
