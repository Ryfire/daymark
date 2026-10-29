# Daymark app icon generator.
# Renders four candidate launcher marks on the teal gradient squircle:
#   cairn   - stacked-stone trail marker (the literal daymark)
#   stripe  - diagonal-striped nautical daymark beacon
#   sheet   - off-white note sheet with a "d" (family look with JotLock)
#   lock    - JotLock's padlock geometry, recolored
# Each run writes 512 px masters plus launcher-size preview strips to
# tool/out/. Once a mark is chosen, regenerate with:
#   python tool/make_icon.py --finalize <mark>
# which writes the density PNGs, adaptive-icon vector XMLs into res, and
# the store icon into assets/images, so PNG and vector stay in sync.
#
# Requires: Pillow

import math
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 1024          # design space (all geometry defined here)
SS = 4            # supersampling factor for raster render
W = S * SS

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "tool", "out")
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
IMAGES = os.path.join(ROOT, "assets", "images")

# Brand colors (Material teal ramp, centered on the app's Colors.teal seed)
TEAL_LIGHT = (0x26, 0xA6, 0x9A)   # teal 400 - top-left
TEAL_DARK = (0x00, 0x79, 0x6B)    # teal 700 - bottom-right
SHEEN_ALPHA = 30                  # peak white sheen (0-255)

SHEET_FILL = (0xF7, 0xF4, 0xEC)   # warm paper
FOLD_FILL = (0xDD, 0xD7, 0xCB)    # folded flap, slightly shaded
INK = TEAL_DARK                   # glyph ink on paper
WHITE = (255, 255, 255)

# ---------------------------------------------------------------- geometry --
def rounded_rect_points(box, r, n=24):
    """Sample a rounded rectangle outline (for rasterization and clipping)."""
    x0, y0, x1, y1 = box
    arcs = [
        ((x1 - r, y0 + r), 270, 360),   # top-right
        ((x1 - r, y1 - r), 0, 90),      # bottom-right
        ((x0 + r, y1 - r), 90, 180),    # bottom-left
        ((x0 + r, y0 + r), 180, 270),   # top-left
    ]
    pts = []
    for (cx, cy), a0, a1 in arcs:
        for i in range(n + 1):
            t = math.radians(a0 + (a1 - a0) * i / n)
            pts.append((cx + r * math.cos(t), cy + r * math.sin(t)))
    return pts


def circle_points(c, r, n=40):
    return [(c[0] + r * math.cos(2 * math.pi * i / n),
             c[1] + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def clip_half_plane(pts, dist):
    """Sutherland-Hodgman clip of a polygon against the half-plane dist(p) >= 0."""
    out = []
    n = len(pts)
    for i in range(n):
        p, q = pts[i], pts[(i + 1) % n]
        dp, dq = dist(p), dist(q)
        if dp >= 0:
            out.append(p)
        if (dp >= 0) != (dq >= 0):
            t = dp / (dp - dq)
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out


# ------------------------------------------------------------- transforms --
def legacy_transform(bbox):
    """Scale glyph so its largest side becomes FRAC of canvas, center it."""
    FRAC = 0.60
    cx = (bbox[0] + bbox[2]) / 2
    cy = (bbox[1] + bbox[3]) / 2
    k = FRAC * S / max(bbox[2] - bbox[0], bbox[3] - bbox[1])
    return lambda p: ((p[0] - cx) * k + S / 2, (p[1] - cy) * k + S / 2), k


def adaptive_transform(bbox):
    """Fit glyph inside the 66dp adaptive safe zone (center circle r=33)."""
    cx = (bbox[0] + bbox[2]) / 2
    cy = (bbox[1] + bbox[3]) / 2
    hx = (bbox[2] - bbox[0]) / 2
    hy = (bbox[3] - bbox[1]) / 2
    fs = 30.0 / math.hypot(hx, hy)
    tx = 54 - cx * fs
    ty = 54 - cy * fs
    return fs, tx, ty


# ---------------------------------------------------------------- drawing --
def linear_gradient(size, a, b):
    # oversized source so the rotated gradient fully covers the square,
    # then center-crop -> smooth diagonal gradient, no diamond banding
    d = int(size * 1.6)
    g = Image.linear_gradient("L").resize((d, d), Image.BICUBIC)
    g = g.rotate(45, expand=True, resample=Image.BICUBIC)
    w, h = g.size
    l, t = (w - size) // 2, (h - size) // 2
    g = g.crop((l, t, l + size, t + size))
    ca = Image.new("RGB", (size, size), a)
    cb = Image.new("RGB", (size, size), b)
    return Image.composite(cb, ca, g)


def rounded_rect_mask(size, box, radius):
    m = Image.new("L", (size * SS, size * SS), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([c * SS for c in box], radius=radius * SS, fill=255)
    return m


def polygon_mask(size, pts):
    m = Image.new("L", (size * SS, size * SS), 0)
    d = ImageDraw.Draw(m)
    d.polygon([(x * SS, y * SS) for x, y in pts], fill=255)
    return m


def stroke_mask(size, pts, width):
    """Thick polyline with round caps and round joints, design-space coords."""
    m = Image.new("L", (size * SS, size * SS), 0)
    d = ImageDraw.Draw(m)
    spts = [(x * SS, y * SS) for x, y in pts]
    d.line(spts, fill=255, width=width * SS, joint="curve")
    cap_r = width * SS / 2
    for end in (spts[0], spts[-1]):
        d.ellipse([end[0] - cap_r, end[1] - cap_r,
                   end[0] + cap_r, end[1] + cap_r], fill=255)
    return m


def teal_canvas():
    """Gradient squircle with the top-left sheen, all marks share it."""
    img = linear_gradient(W, TEAL_LIGHT, TEAL_DARK).convert("RGBA")

    sheen = Image.new("L", (W, W), 0)
    sd = ImageDraw.Draw(sheen)
    scx, scy, r = int(0.30 * W), int(0.24 * W), int(0.52 * W)
    sd.ellipse([scx - r, scy - r, scx + r, scy + r], fill=SHEEN_ALPHA)
    sheen = sheen.filter(ImageFilter.GaussianBlur(W // 9))
    white = Image.new("RGBA", (W, W), WHITE + (255,))
    img.paste(white, (0, 0), sheen)

    squircle = rounded_rect_mask(S, (0, 0, S, S), int(0.223 * S))
    img.putalpha(squircle)
    return img


def paint(img, color, mask):
    img.paste(Image.new("RGBA", (W, W), tuple(color) + (255,)), (0, 0), mask)


# ================================================================= cairn ====
# Three stacked pebbles: capsule stones, widest at the base, equal gaps.
CAIRN_S1 = (296, 624, 728, 806)   # base
CAIRN_S2 = (344, 470, 680, 596)
CAIRN_S3 = (408, 336, 616, 442)   # top
CAIRN_GAP = 28                    # air between stones


def cairn_shapes():
    stones = [CAIRN_S3, CAIRN_S2, CAIRN_S1]
    radii = [53, 63, 91]
    polys = [rounded_rect_points(b, r) for b, r in zip(stones, radii)]
    xs = [p[0] for poly in polys for p in poly]
    ys = [p[1] for poly in polys for p in poly]
    return {"polys": polys, "bbox": (min(xs), min(ys), max(xs), max(ys))}


def render_cairn(img):
    sh = cairn_shapes()
    tr, _k = legacy_transform(sh["bbox"])
    for poly in sh["polys"]:
        paint(img, WHITE, polygon_mask(S, [tr(p) for p in poly]))
    return sh


# ================================================================ stripe ====
# Nautical daymark beacon: tower + pointed roof + base slab, two diagonal
# stripes punched through the tower (the gradient shows through).
STRIPE_TOWER = (430, 396, 594, 758)
STRIPE_TOWER_R = 34
STRIPE_ROOF = [(512, 268), (626, 400), (398, 400)]
STRIPE_BASE = (380, 758, 644, 812)
STRIPE_BASE_R = 27
# Stripes run along x+y = const, matching the background gradient axis.
STRIPE_BANDS = [(700, 840), (1080, 1220)]


def stripe_band_points(c1, c2):
    """Parallelogram for the band c1 <= x + y <= c2, generously oversized."""
    return [(c1, 0), (c2, 0), (c2 - S, S), (c1 - S, S)]


def stripe_shapes():
    tower = rounded_rect_points(STRIPE_TOWER, STRIPE_TOWER_R)
    base = rounded_rect_points(STRIPE_BASE, STRIPE_BASE_R)
    all_pts = tower + base + STRIPE_ROOF
    xs = [p[0] for p in all_pts]
    ys = [p[1] for p in all_pts]
    return {
        "tower": tower,
        "roof": STRIPE_ROOF,
        "base": base,
        "bands": [stripe_band_points(c1, c2) for c1, c2 in STRIPE_BANDS],
        "bbox": (min(xs), min(ys), max(xs), max(ys)),
    }


def render_stripe(img):
    sh = stripe_shapes()
    tr, _k = legacy_transform(sh["bbox"])
    mask = polygon_mask(S, [tr(p) for p in sh["tower"]])
    md = ImageDraw.Draw(mask)
    for band in sh["bands"]:
        md.polygon([(x * SS, y * SS) for x, y in map(tr, band)], fill=0)
    paint(img, WHITE, mask)
    paint(img, WHITE, polygon_mask(S, [tr(p) for p in sh["roof"]]))
    paint(img, WHITE, polygon_mask(S, [tr(p) for p in sh["base"]]))
    return sh


# ================================================================= sheet ====
# Family look with JotLock: warm note sheet, dog-eared top-right corner,
# pencil resting in the notch, and a round-capped lowercase "d" in ink.
DAY_SHEET = (312, 240, 712, 784)
DAY_SHEET_R = 44
DAY_CUT = 120                      # dog-ear size along top and right edges
DAY_BOWL_C = (452, 584)            # d bowl: stroke centerline circle
DAY_BOWL_R = 74
DAY_BOWL_STROKE = 64
DAY_STEM_X = 558                   # d stem, right of the bowl
DAY_STEM_TOP = 408
DAY_STEM_BOTTOM = 668
# Pencil resting in the dog-ear notch, parallel to the crease with the
# 14-unit flush gap motif from JotLock's launcher pencil.
DAY_PENCIL_REAR = (616, 220)
DAY_PENCIL_AXIS = (math.cos(math.pi / 4), math.sin(math.pi / 4))
DAY_PENCIL_LEN = 156               # rear end to tip apex
DAY_PENCIL_TIP = 40
DAY_PENCIL_HW = 17                 # half width


def sheet_pencil_points():
    ux, uy = DAY_PENCIL_AXIS
    nx, ny = -uy, ux               # perpendicular (width direction)
    rx, ry = DAY_PENCIL_REAR
    L, tip, hw = DAY_PENCIL_LEN, DAY_PENCIL_TIP, DAY_PENCIL_HW
    apex = (rx + ux * L, ry + uy * L)
    tb = (rx + ux * (L - tip), ry + uy * (L - tip))
    return [
        (rx - nx * hw, ry - ny * hw),
        (tb[0] - nx * hw, tb[1] - ny * hw),
        apex,
        (tb[0] + nx * hw, tb[1] + ny * hw),
        (rx + nx * hw, ry + ny * hw),
    ]


def sheet_shapes():
    x0, y0, x1, y1 = DAY_SHEET
    cut_x = x1 - DAY_CUT           # cut meets the top edge here
    cut_y = y0 + DAY_CUT           # cut meets the right edge here
    # cut line: x - y = cut_x - y0 ; interior lies at smaller x - y
    sheet = clip_half_plane(rounded_rect_points(DAY_SHEET, DAY_SHEET_R),
                            lambda p: (cut_x - y0) - (p[0] - p[1]))
    fold = [(cut_x, y0), (x1, cut_y), (cut_x, cut_y)]
    pencil = sheet_pencil_points()
    all_pts = sheet + fold + pencil
    xs = [p[0] for p in all_pts]
    ys = [p[1] for p in all_pts]
    return {"sheet": sheet, "fold": fold, "pencil": pencil,
            "bbox": (min(xs), min(ys), max(xs), max(ys))}


def render_sheet(img):
    sh = sheet_shapes()
    tr, _k = legacy_transform(sh["bbox"])

    paint(img, SHEET_FILL, polygon_mask(S, [tr(p) for p in sh["sheet"]]))

    # pencil first, so the fold flap painted next hides its rear end
    paint(img, WHITE, polygon_mask(S, [tr(p) for p in sh["pencil"]]))
    paint(img, FOLD_FILL, polygon_mask(S, [tr(p) for p in sh["fold"]]))

    # lowercase d: stroked bowl circle + straight stem, round caps/joints
    cx, cy = DAY_BOWL_C
    r = DAY_BOWL_R
    bowl_pts = [(cx + r * math.cos(2 * math.pi * i / 40),
                 cy + r * math.sin(2 * math.pi * i / 40)) for i in range(41)]
    paint(img, INK, stroke_mask(S, map(tr, bowl_pts), DAY_BOWL_STROKE))
    stem = [(DAY_STEM_X, DAY_STEM_TOP), (DAY_STEM_X, DAY_STEM_BOTTOM)]
    paint(img, INK, stroke_mask(S, map(tr, stem), DAY_BOWL_STROKE))
    return sh


# ================================================================== lock ====
# JotLock's padlock geometry, standalone: shackle ring, rounded body,
# keyhole circle + tapered slot punched through.
LOCK_BODY = (280, 520, 640, 830)
LOCK_BODY_R = 72
LOCK_KEY_C = (452, 634)
LOCK_KEY_R = 34
LOCK_SLOT = [(440, 668), (464, 668), (468, 706), (436, 706)]
LOCK_SH_C = (460, 520)
LOCK_SH_RO = 130
LOCK_SH_RI = 74
LOCK_SH_LEG_Y = 578


def lock_shackle_points():
    cx, cy = LOCK_SH_C
    pts = [(cx - LOCK_SH_RO, LOCK_SH_LEG_Y), (cx - LOCK_SH_RO, cy)]
    n = 48
    for i in range(n + 1):          # outer arc, pi..2pi (over the top)
        t = math.pi + math.pi * i / n
        pts.append((cx + LOCK_SH_RO * math.cos(t), cy + LOCK_SH_RO * math.sin(t)))
    pts += [(cx + LOCK_SH_RO, LOCK_SH_LEG_Y), (cx + LOCK_SH_RI, LOCK_SH_LEG_Y),
            (cx + LOCK_SH_RI, cy)]
    for i in range(n + 1):          # inner arc, back 2pi..pi
        t = 2 * math.pi - math.pi * i / n
        pts.append((cx + LOCK_SH_RI * math.cos(t), cy + LOCK_SH_RI * math.sin(t)))
    pts += [(cx - LOCK_SH_RI, LOCK_SH_LEG_Y)]
    return pts


def lock_shapes():
    body = rounded_rect_points(LOCK_BODY, LOCK_BODY_R)
    shackle = lock_shackle_points()
    all_pts = body + shackle
    xs = [p[0] for p in all_pts]
    ys = [p[1] for p in all_pts]
    return {
        "body": body,
        "keyhole": circle_points(LOCK_KEY_C, LOCK_KEY_R),
        "slot": LOCK_SLOT,
        "shackle": shackle,
        "bbox": (min(xs), min(ys), max(xs), max(ys)),
    }


def render_lock(img):
    sh = lock_shapes()
    tr, _k = legacy_transform(sh["bbox"])
    mask = polygon_mask(S, [tr(p) for p in sh["body"]])
    md = ImageDraw.Draw(mask)
    md.polygon([(x * SS, y * SS) for x, y in map(tr, sh["keyhole"])], fill=0)
    md.polygon([(x * SS, y * SS) for x, y in map(tr, sh["slot"])], fill=0)
    paint(img, WHITE, mask)
    paint(img, WHITE, polygon_mask(S, [tr(p) for p in sh["shackle"]]))
    return sh


MARKS = {"cairn": render_cairn, "stripe": render_stripe,
         "sheet": render_sheet, "lock": render_lock}


def render_master(mark, size_out):
    """Render one mark on the teal squircle and return an RGBA image."""
    img = teal_canvas()
    sh = MARKS[mark](img)
    return img.resize((size_out, size_out), Image.LANCZOS), sh


# ------------------------------------------------------------- vector xml --
def fmt(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return s if s else "0"


def path_poly(pts):
    d = f"M{fmt(pts[0][0])},{fmt(pts[0][1])}"
    for p in pts[1:]:
        d += f" L{fmt(p[0])},{fmt(p[1])}"
    return d + " Z"


def path_circle(c, r):
    return (f"M{fmt(c[0]-r)},{fmt(c[1])} "
            f"A{fmt(r)},{fmt(r)} 0 1 0 {fmt(c[0]+r)},{fmt(c[1])} "
            f"A{fmt(r)},{fmt(r)} 0 1 0 {fmt(c[0]-r)},{fmt(c[1])} Z")


def path_rounded_rect(box, r):
    x0, y0, x1, y1 = box
    return (f"M{fmt(x0+r)},{fmt(y0)} H{fmt(x1-r)} "
            f"A{fmt(r)},{fmt(r)} 0 0 1 {fmt(x1)},{fmt(y0+r)} "
            f"V{fmt(y1-r)} A{fmt(r)},{fmt(r)} 0 0 1 {fmt(x1-r)},{fmt(y1)} "
            f"H{fmt(x0+r)} A{fmt(r)},{fmt(r)} 0 0 1 {fmt(x0)},{fmt(y1-r)} "
            f"V{fmt(y0+r)} A{fmt(r)},{fmt(r)} 0 0 1 {fmt(x0+r)},{fmt(y0)} Z")


def hex6(color):
    return "#%02X%02X%02X" % tuple(color)


def foreground_xml(mark):
    if mark == "cairn":
        sh = cairn_shapes()
        paths = "".join(
            f'\n        <path\n            android:fillColor="#FFFFFFFF"\n'
            f'            android:pathData="{path_rounded_rect(box, r)}" />'
            for box, r in zip((CAIRN_S3, CAIRN_S2, CAIRN_S1), (53, 63, 91)))
        comment = "three stacked capsule stones"
    elif mark == "stripe":
        sh = stripe_shapes()
        bands = " ".join(path_poly(b) for b in sh["bands"])
        tower = (path_rounded_rect(STRIPE_TOWER, STRIPE_TOWER_R) + " " + bands)
        paths = (
            f'\n        <path\n            android:fillColor="#FFFFFFFF"\n'
            f'            android:fillType="evenOdd"\n'
            f'            android:pathData="{tower}" />'
            f'\n        <path\n            android:fillColor="#FFFFFFFF"\n'
            f'            android:pathData="{path_poly(sh["roof"])}" />'
            f'\n        <path\n            android:fillColor="#FFFFFFFF"\n'
            f'            android:pathData="{path_rounded_rect(STRIPE_BASE, STRIPE_BASE_R)}" />')
        comment = "beacon tower with two diagonal stripes punched through"
    elif mark == "sheet":
        sh = sheet_shapes()
        x0, y0, x1, y1 = DAY_SHEET
        r = DAY_SHEET_R
        cut_x = x1 - DAY_CUT
        cut_y = y0 + DAY_CUT
        sheet_path = (f"M{fmt(x0 + r)},{fmt(y0)} H{fmt(cut_x)} "
                      f"L{fmt(x1)},{fmt(cut_y)} V{fmt(y1 - r)} "
                      f"A{fmt(r)},{fmt(r)} 0 0 1 {fmt(x1 - r)},{fmt(y1)} "
                      f"H{fmt(x0 + r)} "
                      f"A{fmt(r)},{fmt(r)} 0 0 1 {fmt(x0)},{fmt(y1 - r)} "
                      f"V{fmt(y0 + r)} "
                      f"A{fmt(r)},{fmt(r)} 0 0 1 {fmt(x0 + r)},{fmt(y0)} Z")
        cx, cy = DAY_BOWL_C
        rr = DAY_BOWL_R
        stroke = fmt(DAY_BOWL_STROKE)
        bowl = (f"M{fmt(cx - rr)},{fmt(cy)} "
                f"A{fmt(rr)},{fmt(rr)} 0 1 0 {fmt(cx + rr)},{fmt(cy)} "
                f"A{fmt(rr)},{fmt(rr)} 0 1 0 {fmt(cx - rr)},{fmt(cy)}")
        stem = (f"M{fmt(DAY_STEM_X)},{fmt(DAY_STEM_TOP)} "
                f"L{fmt(DAY_STEM_X)},{fmt(DAY_STEM_BOTTOM)}")
        paths = (
            f'\n        <path\n            android:fillColor="#FFF7F4EC"\n'
            f'            android:pathData="{sheet_path}" />'
            f'\n        <!-- pencil resting in the notch -->\n'
            f'        <path\n            android:fillColor="#FFFFFFFF"\n'
            f'            android:pathData="{path_poly(sh["pencil"])}" />'
            f'\n        <!-- folded flap -->\n'
            f'        <path\n            android:fillColor="#FFDDD7CB"\n'
            f'            android:pathData="{path_poly(sh["fold"])}" />'
            f'\n        <!-- lowercase d -->\n'
            f'        <path\n            android:strokeColor="#FF00796B"\n'
            f'            android:strokeWidth="{stroke}"\n'
            f'            android:strokeLineCap="round"\n'
            f'            android:pathData="{bowl}" />'
            f'\n        <path\n            android:strokeColor="#FF00796B"\n'
            f'            android:strokeWidth="{stroke}"\n'
            f'            android:strokeLineCap="round"\n'
            f'            android:pathData="{stem}" />')
        comment = "dog-eared note sheet with a round-capped d"
    elif mark == "lock":
        sh = lock_shapes()
        cx, cy = LOCK_SH_C
        ro, ri, ly = LOCK_SH_RO, LOCK_SH_RI, LOCK_SH_LEG_Y
        shackle = (f"M{fmt(cx-ro)},{fmt(ly)} L{fmt(cx-ro)},{fmt(cy)} "
                   f"A{fmt(ro)},{fmt(ro)} 0 0 1 {fmt(cx+ro)},{fmt(cy)} "
                   f"L{fmt(cx+ro)},{fmt(ly)} L{fmt(cx+ri)},{fmt(ly)} "
                   f"L{fmt(cx+ri)},{fmt(cy)} "
                   f"A{fmt(ri)},{fmt(ri)} 0 0 0 {fmt(cx-ri)},{fmt(cy)} "
                   f"L{fmt(cx-ri)},{fmt(ly)} Z")
        keyhole = (path_circle(LOCK_KEY_C, LOCK_KEY_R) + " " +
                   path_poly(LOCK_SLOT))
        paths = (
            f'\n        <!-- shackle -->\n'
            f'        <path\n            android:fillColor="#FFFFFFFF"\n'
            f'            android:pathData="{shackle}" />'
            f'\n        <!-- body with punched keyhole (even-odd) -->\n'
            f'        <path\n            android:fillColor="#FFFFFFFF"\n'
            f'            android:fillType="evenOdd"\n'
            f'            android:pathData="{path_rounded_rect(LOCK_BODY, LOCK_BODY_R)} {keyhole}" />')
        comment = "padlock with punched keyhole"
    else:
        raise SystemExit(f"unknown mark: {mark}")

    fs, tx, ty = adaptive_transform(sh["bbox"])
    return f"""<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- Daymark: {comment}, on the teal gradient. Geometry lives in a
         1024x1024 design space; the group maps it into the 108dp viewport
         and keeps it inside the 66dp safe zone. Regenerate by running
         tool/make_icon.py with the finalize flag and mark "{mark}". -->
    <group
        android:scaleX="{fs:.6f}"
        android:scaleY="{fs:.6f}"
        android:translateX="{tx:.2f}"
        android:translateY="{ty:.2f}">{paths}
    </group>
</vector>
"""


BACKGROUND_XML = """<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <!-- teal diagonal gradient, top-left to bottom-right -->
    <path android:pathData="M0,0 H108 V108 H0 Z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="0"
                android:startY="0"
                android:endX="108"
                android:endY="108">
                <item android:offset="0" android:color="#FF26A69A" />
                <item android:offset="1" android:color="#FF00796B" />
            </gradient>
        </aapt:attr>
    </path>
    <!-- soft sheen highlight, top-left -->
    <path android:pathData="M0,0 H108 V108 H0 Z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="radial"
                android:centerX="32"
                android:centerY="26"
                android:gradientRadius="56">
                <item android:offset="0" android:color="#24FFFFFF" />
                <item android:offset="1" android:color="#00FFFFFF" />
            </gradient>
        </aapt:attr>
    </path>
</vector>
"""


# ---------------------------------------------------------------- previews --
def preview_strip(master, name, mark):
    for kind, bg in (("dark", (28, 27, 31)), ("light", (250, 250, 250))):
        strip = Image.new("RGB", (5 * 200 + 60, 220), bg)
        for i, px in enumerate((48, 72, 96, 144, 192)):
            ic = master.resize((px, px), Image.LANCZOS)
            strip.paste(ic, (30 + i * 200 + (192 - px) // 2,
                             110 - px // 2), ic)
        strip.save(os.path.join(OUT, f"daymark_{mark}_preview_{kind}.png"))


def preview_grid(masters):
    """2x2 grid of all candidate marks, 512 px each, on a neutral wall."""
    pad, cell = 24, 560
    grid = Image.new("RGB", (2 * cell + 3 * pad, 2 * cell + 3 * pad),
                     (238, 238, 236))
    for i, (mark, m) in enumerate(masters.items()):
        ic = m.resize((512, 512), Image.LANCZOS)
        x, y = pad + (i % 2) * cell, pad + (i // 2) * cell
        grid.paste(ic, (x, y), ic)
    grid.save(os.path.join(OUT, "daymark_all_previews.png"))


def write_previews():
    os.makedirs(OUT, exist_ok=True)
    masters = {}
    for mark in MARKS:
        master, sh = render_master(mark, S)
        masters[mark] = master
        master.save(os.path.join(OUT, f"daymark_{mark}_1024.png"))
        master.resize((512, 512), Image.LANCZOS).save(
            os.path.join(OUT, f"daymark_{mark}_512.png"))
        preview_strip(master, None, mark)
        print(f"{mark}: bbox={tuple(round(v, 1) for v in sh['bbox'])}")
    preview_grid(masters)
    print("previews written to", OUT)


def finalize(mark):
    if mark not in MARKS:
        raise SystemExit(f"unknown mark: {mark} (choose one of {list(MARKS)})")
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(IMAGES, exist_ok=True)

    master, sh = render_master(mark, S)
    master.save(os.path.join(OUT, f"daymark_{mark}_1024.png"))
    preview_strip(master, None, mark)

    densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144,
                 "xxxhdpi": 192}
    for dpi, px in densities.items():
        d = os.path.join(RES, f"mipmap-{dpi}")
        os.makedirs(d, exist_ok=True)
        master.resize((px, px), Image.LANCZOS).save(
            os.path.join(d, "ic_launcher.png"))
        master.resize((px, px), Image.LANCZOS).save(
            os.path.join(d, "ic_launcher_round.png"))

    anydpi = os.path.join(RES, "mipmap-anydpi-v26")
    os.makedirs(anydpi, exist_ok=True)
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        with open(os.path.join(anydpi, name), "w") as f:
            f.write(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android='
                '"http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable='
                '"@drawable/ic_launcher_background" />\n'
                '    <foreground android:drawable='
                '"@drawable/ic_launcher_foreground" />\n'
                '    <monochrome android:drawable='
                '"@drawable/ic_launcher_foreground" />\n'
                '</adaptive-icon>\n')

    for name, content in (("ic_launcher_foreground.xml", foreground_xml(mark)),
                          ("ic_launcher_background.xml", BACKGROUND_XML)):
        with open(os.path.join(RES, "drawable", name), "w") as f:
            f.write(content)

    master.resize((512, 512), Image.LANCZOS).save(
        os.path.join(IMAGES, "daymark_icon.png"))
    print(f"finalized '{mark}' into res + assets/images "
          f"(bbox={tuple(round(v, 1) for v in sh['bbox'])})")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--finalize":
        finalize(sys.argv[2])
    else:
        write_previews()
