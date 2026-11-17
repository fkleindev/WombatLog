"""Generates WombatLog's media files (textures and crit sounds).

Requires: pip install numpy soundfile
Run from the repository root: python tools/gen_media.py
"""
import os
import struct

import numpy as np
import soundfile as sf

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
MEDIA = os.path.join(ROOT, "Media")
SOUNDS = os.path.join(MEDIA, "Sounds")
RATE = 44100


# --- textures ---------------------------------------------------------------

def write_tga(path, width, height, alpha):
    """Uncompressed 32-bit TGA, white RGB with the given alpha (rows bottom-up)."""
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 8)
    a = np.clip(alpha, 0, 255).astype(np.uint8)
    pixels = np.empty((height, width, 4), np.uint8)
    pixels[..., :3] = 255
    pixels[..., 3] = a
    with open(path, "wb") as f:
        f.write(header + pixels.tobytes())


def gen_textures():
    # Gradient: alpha 255 -> 0 left to right (row backgrounds)
    ramp = 255 - np.arange(256)
    write_tga(os.path.join(MEDIA, "Gradient.tga"), 256, 4, np.tile(ramp, (4, 1)))

    # Glow: soft radial burst (crit alert)
    n = 128
    y, x = np.mgrid[0:n, 0:n]
    r = np.hypot(x - (n - 1) / 2, y - (n - 1) / 2) / (n / 2)
    glow = np.clip(1 - r, 0, 1) ** 2.2 * 255
    write_tga(os.path.join(MEDIA, "Glow.tga"), n, n, glow)

    # Corner: a quarter disc rounding off a bottom-left corner (XP tracker's panel;
    # mirrored for the bottom-right one). The disc's center is the top-right corner.
    write_tga(os.path.join(MEDIA, "Corner.tga"), 32, 32, corner(32))

    # Round00-50: rounded squares, the corner radius in percent of the side (modern
    # action buttons: icon mask, border, background and states; 50 = a circle)
    for pct in range(0, 51, 5):
        write_tga(os.path.join(MEDIA, f"Round{pct:02d}.tga"), 64, 64, rounded_square(64, pct / 100))

    # Shine: a soft bright band in the middle, fading out to both sides; repeats
    # sideways (glint running over the power bar's spell cost mark)
    x = np.arange(128)
    band = np.exp(-(((x - 63.5) / 14) ** 2)) * 255
    write_tga(os.path.join(MEDIA, "Shine.tga"), 128, 4, np.tile(band, (4, 1)))

    # Wings / WingsLeft: a stylized dragon ornament for elite, rare and boss targets,
    # blades fanning out behind the portrait (the portrait covers the middle half)
    wings = gen_wings(256)
    write_tga(os.path.join(MEDIA, "Wings.tga"), 256, 256, wings)
    write_tga(os.path.join(MEDIA, "WingsLeft.tga"), 256, 256, wings[:, ::-1])

    # Ornament<Style> / Ornament<Style>Left: the other ornament styles, same layout;
    # the dragon's head is a texture of its own, drawn over the portrait
    ornaments = {f"Ornament{name}": alpha for name, alpha in gen_ornaments(256).items()}
    for name, alpha in ornaments.items():
        write_tga(os.path.join(MEDIA, f"{name}.tga"), 256, 256, alpha)
        write_tga(os.path.join(MEDIA, f"{name}Left.tga"), 256, 256, alpha[:, ::-1])

    # <Ornament>Outline / <Ornament>OutlineLeft: a thin rim around each ornament,
    # drawn behind it in a color of the player's choice
    ornaments["Wings"] = wings
    for name, alpha in ornaments.items():
        rim = outline(alpha)
        write_tga(os.path.join(MEDIA, f"{name}Outline.tga"), 256, 256, rim)
        write_tga(os.path.join(MEDIA, f"{name}OutlineLeft.tga"), 256, 256, rim[:, ::-1])

    gen_rings()
    gen_icons()
    gen_flight()


def gen_icons():
    """Small round-capped line icons (quest tracker): a chevron pointing down, and
    three lines of falling length for the compact view."""
    c = Canvas(32)
    c.add(sd_stroke(c, [(-0.55, 0.22), (0, -0.30), (0.55, 0.22)], 0.13, 0.13))
    write_tga(os.path.join(MEDIA, "Chevron.tga"), 32, 32, c.alpha * 255)
    c = Canvas(32)
    for y, half in ((0.5, 0.62), (0, 0.42), (-0.5, 0.22)):
        c.add(sd_stroke(c, [(-0.62, y), (-0.62 + 2 * half, y)], 0.12, 0.12))
    write_tga(os.path.join(MEDIA, "Lines.tga"), 32, 32, c.alpha * 255)


# blades: base angle (degrees, 0 = outward, positive = up), length, base half-width
# (degrees), sweep (degrees the tip bends away from the middle)
WING_BLADES = ((0, 0.97, 13, 0), (32, 0.93, 12, 16), (-32, 0.93, 12, 16),
               (62, 0.86, 11, 22), (-62, 0.86, 11, 22), (92, 0.74, 9, 26), (-92, 0.74, 9, 26))


def gen_wings(n):
    """Alpha of the ornament pointing right, in a texture twice the portrait's size."""
    row, col = np.mgrid[0:n, 0:n]  # rows bottom-up, as write_tga stores them
    x = (col + 0.5) / (n / 2) - 1
    y = (row + 0.5) / (n / 2) - 1
    r = np.hypot(x, y)
    phi = np.degrees(np.arctan2(y, x))
    px = n / 2  # pixels per unit
    alpha = np.zeros((n, n))
    r0 = 0.42  # blades start under the portrait's edge
    for base, length, width, sweep in WING_BLADES:
        t = np.clip((r - r0) / (length - r0), 0, 1)
        side = np.sign(base) if base else 0
        center = base + side * sweep * t ** 1.6
        half = width * (1 - t) ** 0.9 + 0.4
        # distance to the blade's edge in pixels, along the arc
        d = (np.abs(phi - center) - half) * np.pi / 180 * r * px
        a = np.clip(0.5 - d, 0, 1)
        a *= np.clip((length - r) * px + 0.5, 0, 1)  # soft tip
        a *= np.clip((r - r0) * px + 0.5, 0, 1)
        # a slight fade toward the tip, so the blades look lit from the portrait
        alpha = np.maximum(alpha, a * (1 - 0.35 * t))
    return alpha * 255


# --- ornament styles ----------------------------------------------------------
# Every style is drawn pointing right (away from the bars) in a texture twice the
# portrait's size: the portrait covers the middle half, x and y run from -1 to 1.
# Shapes are signed distances (negative inside), turned into antialiased alpha.

class Canvas:
    def __init__(self, n):
        self.n = n
        row, col = np.mgrid[0:n, 0:n]  # rows bottom-up, as write_tga stores them
        self.x = (col + 0.5) / (n / 2) - 1
        self.y = (row + 0.5) / (n / 2) - 1
        self.alpha = np.zeros((n, n))

    def coverage(self, d):
        return np.clip(0.5 - d * self.n / 2, 0, 1)

    def add(self, d, strength=1.0):
        self.alpha = np.maximum(self.alpha, self.coverage(d) * strength)

    def cut(self, d):
        self.alpha *= 1 - self.coverage(d)

    def mirror_y(self):
        """Adds the shape's reflection across the horizontal middle."""
        self.alpha = np.maximum(self.alpha, self.alpha[::-1, :])

    def result(self, fade=0.35):
        """Alpha 0-255, fading a little from the portrait's edge outward."""
        t = np.clip((np.hypot(self.x, self.y) - 0.5) / 0.5, 0, 1)
        return self.alpha * (1 - fade * t) * 255


def polar(r, deg):
    a = np.radians(deg)
    return np.array([r * np.cos(a), r * np.sin(a)])


def bezier(ctrl, m=64):
    """Points along a Bezier curve through the control points (de Casteljau)."""
    t = np.linspace(0, 1, m)[:, None]
    p = [np.asarray(c, float) for c in ctrl]
    while len(p) > 1:
        p = [(1 - t) * a + t * b for a, b in zip(p, p[1:])]
    return p[0]


def spline(points, m=160):
    """Points along a Catmull-Rom curve through the given points."""
    p = np.asarray(points, float)
    p = np.vstack([2 * p[0] - p[1], p, 2 * p[-1] - p[-2]])
    out = []
    per = max(2, m // (len(p) - 3))
    for i in range(1, len(p) - 2):
        p0, p1, p2, p3 = p[i - 1], p[i], p[i + 1], p[i + 2]
        t = np.linspace(0, 1, per, endpoint=i == len(p) - 3)[:, None]
        out.append(0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t ** 2
                          + (3 * p1 - p0 - 3 * p2 + p3) * t ** 3))
    return np.vstack(out)


def sd_circle(c, center, r):
    return np.hypot(c.x - center[0], c.y - center[1]) - r


def sd_stroke(c, pts, r0, r1=None, shape=1.0):
    """A line along pts, r0 thick at its start and r1 at its end, or radii per point."""
    pts = np.asarray(pts, float)
    if r1 is None:
        radii = np.asarray(r0, float)
    else:
        radii = r0 + (r1 - r0) * np.linspace(0, 1, len(pts)) ** shape
    d = np.full(c.x.shape, np.inf)
    for (ax, ay), (bx, by), ra, rb in zip(pts, pts[1:], radii, radii[1:]):
        ex, ey = bx - ax, by - ay
        wx, wy = c.x - ax, c.y - ay
        h = np.clip((wx * ex + wy * ey) / max(ex * ex + ey * ey, 1e-12), 0, 1)
        d = np.minimum(d, np.hypot(wx - ex * h, wy - ey * h) - (ra + (rb - ra) * h))
    return d


def sd_polygon(c, pts):
    pts = np.asarray(pts, float)
    d = np.full(c.x.shape, np.inf)
    inside = np.zeros(c.x.shape, bool)
    for (ax, ay), (bx, by) in zip(pts, np.roll(pts, -1, axis=0)):
        ex, ey = bx - ax, by - ay
        wx, wy = c.x - ax, c.y - ay
        h = np.clip((wx * ex + wy * ey) / max(ex * ex + ey * ey, 1e-12), 0, 1)
        d = np.minimum(d, np.hypot(wx - ex * h, wy - ey * h))
        if ey != 0:
            crosses = (ay > c.y) != (by > c.y)
            inside ^= crosses & (c.x < ax + (c.y - ay) * ex / ey)
    return np.where(inside, -d, d)


def leaf(base, deg, length, width, m=24):
    """An almond-shaped leaf from base, pointing deg, fullest a little before the middle."""
    s = np.linspace(0, 1, m)
    half = width / 2 * np.sin(np.pi * s ** 0.8) ** 0.9
    u, v = polar(1, deg), polar(1, deg + 90)
    along = np.asarray(base) + np.outer(s * length, u)
    return np.vstack([along + np.outer(half, v), (along - np.outer(half, v))[::-1]])


def spike(base, deg, length, width, bend=0.25, m=16):
    """A pointed spike from base, pointing deg, its sides curving in a little."""
    u, v = polar(1, deg), polar(1, deg + 90)
    base = np.asarray(base, float)
    tip = base + u * length
    left, right = base + v * width / 2, base - v * width / 2
    mid = base + u * length * 0.5
    side_l = bezier([left, mid + v * width / 2 * (1 - 2 * bend), tip], m)
    side_r = bezier([tip, mid - v * width / 2 * (1 - 2 * bend), right], m)
    return np.vstack([side_l, side_r[1:]])


def gen_laurel(n):
    """Two laurel branches tied at the outer middle, reaching up and down around the portrait."""
    c = Canvas(n)
    R, ends = 0.68, (4, 112)
    stem = np.array([polar(R, a) for a in np.linspace(*ends, 48)])
    c.add(sd_stroke(c, stem, 0.020, 0.008))
    for k, a in enumerate(range(10, 101, 18)):
        size = 1 - 0.07 * k
        c.add(sd_polygon(c, leaf(polar(R, a), a + 45, 0.30 * size, 0.13 * size)))
        c.add(sd_polygon(c, leaf(polar(R, a + 9), a + 9 + 130, 0.25 * size, 0.11 * size)))
    c.add(sd_polygon(c, leaf(polar(R, ends[1] - 2), ends[1] + 90, 0.17, 0.08)))
    c.mirror_y()
    c.add(sd_circle(c, polar(R + 0.01, 0), 0.05))
    for a in (-11, 11):
        c.add(sd_circle(c, polar(R + 0.11, a), 0.032))
    return c.result()


def gen_crown(n):
    """A crown on top of the portrait: a band with five points, a jewel on each."""
    c = Canvas(n)
    band = np.array([polar(0.56, a) for a in np.linspace(90 - 56, 90 + 56, 48)])
    c.add(sd_stroke(c, band, 0.065, 0.065))
    for off, tip in ((0, 0.93), (23, 0.86), (46, 0.76)):
        for a in {90 - off, 90 + off}:
            c.add(sd_polygon(c, spike(polar(0.6, a), a, tip - 0.6, 0.25 if off == 0 else 0.22, bend=0.3)))
            c.add(sd_circle(c, polar(tip, a), 0.048))
    # a gap between the band and the points, so they read as two parts
    gap = np.array([polar(0.64, a) for a in np.linspace(90 - 60, 90 + 60, 48)])
    c.cut(sd_stroke(c, gap, 0.012, 0.012))
    return c.result(fade=0.25)


def flame(c, deg, length, width, lean=0.55, sway=0.06, strength=1.0):
    """A flame tongue from behind the portrait, leaning upward, an S in its sway."""
    base = polar(0.40, deg)
    u = polar(1, deg) + np.array((0, lean))
    u /= np.hypot(*u)
    v = np.array((-u[1], u[0]))
    reach = length - 0.40
    pts = bezier([base, base + u * reach * 0.35 + v * sway,
                  base + u * reach * 0.7 - v * sway, base + u * reach], 64)
    t = np.linspace(0, 1, len(pts))
    c.add(sd_stroke(c, pts, width * (1 - t) ** 1.2 * (1 + 0.8 * np.sin(np.pi * t ** 0.7))), strength)


def gen_flames(n):
    """Flame tongues blazing from the portrait's outer side, rising like fire does."""
    c = Canvas(n)
    # small tongues in between, a little fainter, then the big ones over them
    for a in range(-48, 97, 24):
        flame(c, a, 0.74 - 0.0012 * abs(a - 20), 0.05, sway=-0.04, strength=0.72)
    for a in range(-60, 109, 24):
        flame(c, a, 0.97 - 0.0022 * abs(a - 24), 0.07)
    return c.result()


def gen_rays(n):
    """A halo of rays around the portrait, long and short in turn, on a thin ring."""
    c = Canvas(n)
    for k, a in enumerate(range(-110, 111, 10)):
        long = k % 2 == 0
        length = 0.97 - 0.14 * (a / 110) ** 2 if long else 0.75 - 0.06 * (a / 110) ** 2
        width = 0.08 if long else 0.06
        c.add(sd_polygon(c, spike(polar(0.635, a), a, length - 0.635, width, bend=0.1)))
    # the rays start a little past the ring, so it stays a clean line
    ring = np.array([polar(0.575, a) for a in np.linspace(-116, 116, 96)])
    c.add(sd_stroke(c, ring, 0.026, 0.026))
    return c.result(fade=0.4)


DRAGON_SHOULDER = (0.40, 0.30)
DRAGON_WRIST = (0.62, 0.80)


def gen_dragon(n):
    """After the old elite dragon: a bat wing raised over the portrait's outer side,
    the body curling around below it and ending in a spade-tipped tail."""
    c = Canvas(n)
    S, W = np.array(DRAGON_SHOULDER), np.array(DRAGON_WRIST)
    tips = [np.array(p) for p in ((0.93, 0.90), (0.98, 0.58), (0.90, 0.24))]
    root = np.array((0.50, 0.02))
    # the membrane, its edge scalloped between the finger tips
    edge = [S, W, tips[0]]
    for a, b in zip(tips, tips[1:] + [root]):
        ctrl = (a + b) / 2 + (W - (a + b) / 2) * 0.32
        edge.extend(bezier([a, ctrl, b], 16)[1:])
    c.add(sd_polygon(c, np.vstack(edge)), 0.62)
    # the bones over it: the arm, the fingers and a claw at the wrist
    c.add(sd_stroke(c, bezier([S, (0.44, 0.62), W], 32), 0.042, 0.026))
    for tip in tips:
        c.add(sd_stroke(c, bezier([W, (W + tip) / 2 + np.array((0.02, 0.02)), tip], 32), 0.024, 0.005))
    c.add(sd_stroke(c, bezier([W, W + (-0.02, 0.10), W + (-0.10, 0.15)], 24), 0.026, 0.002))

    # the body and the tail curling around below the portrait
    path = spline([(0.40, -0.05), (0.72, -0.22), (0.80, -0.56), (0.52, -0.82), (0.10, -0.88), (-0.30, -0.74)], 200)
    c.add(sd_stroke(c, path, 0.13, 0.022, shape=0.8))
    # spikes along its back
    seg = np.diff(path, axis=0)
    for i in np.linspace(len(path) * 0.18, len(path) * 0.72, 6).astype(int):
        tangent = seg[i] / np.hypot(*seg[i])
        normal = path[i] / np.hypot(*path[i])
        r = 0.13 + (0.022 - 0.13) * (i / len(path)) ** 0.8
        deg = np.degrees(np.arctan2(*(normal + tangent * 0.5)[::-1]))
        c.add(sd_polygon(c, spike(path[i] + normal * r * 0.6, deg, r * 0.4 + 0.07, 0.07, bend=0.2)))
    # the spade at the tail's end
    end, before = path[-1], path[-12]
    deg = np.degrees(np.arctan2(*(end - before)[::-1]))
    c.add(sd_polygon(c, spike(end - polar(0.03, deg), deg, 0.15, 0.13, bend=-0.15)))
    return c.result(fade=0.25)


def gen_dragon_head(n):
    """The dragon's head and neck, resting on the portrait's top edge, looking inward."""
    c = Canvas(n)
    head = [(-0.25, 0.585), (-0.21, 0.628), (-0.07, 0.648), (0.03, 0.705), (0.14, 0.722),
            (0.25, 0.695), (0.35, 0.625), (0.45, 0.50), (0.52, 0.36), (0.40, 0.34),
            (0.30, 0.44), (0.15, 0.515), (0.0, 0.497), (-0.12, 0.52), (-0.22, 0.548)]
    c.add(sd_polygon(c, spline(head + head[:1], 240)[:-1]))
    # horns sweeping back, a spike under the jaw and a frill along the neck
    c.add(sd_stroke(c, bezier([(0.06, 0.69), (0.12, 0.84), (0.30, 0.93)], 40), 0.034, 0.003))
    c.add(sd_stroke(c, bezier([(0.16, 0.69), (0.28, 0.79), (0.42, 0.80)], 40), 0.028, 0.003))
    c.add(sd_polygon(c, spike((0.15, 0.53), -125, 0.11, 0.06, bend=0.15)))
    for p, deg in (((0.31, 0.64), 55), ((0.40, 0.55), 40), ((0.47, 0.44), 25)):
        c.add(sd_polygon(c, spike(p, deg, 0.08, 0.06, bend=0.2)))
    # the eye and the mouth, cut out
    c.cut(sd_polygon(c, leaf((-0.04, 0.615), 18, 0.085, 0.032)))
    c.cut(sd_stroke(c, bezier([(-0.27, 0.566), (-0.14, 0.565), (-0.03, 0.548)], 32), 0.010, 0.006))
    return c.result(fade=0.2)


def outline(alpha, radius=4.5):
    """Alpha 0-255 of a rim `radius` texture pixels wide just outside the shape. The
    shape's fade is undone first, so the rim stays solid where the ornament fades."""
    shape = np.clip(alpha / 255 / 0.6, 0, 1)
    n = shape.shape[0]
    k = int(np.ceil(radius))
    pad = np.pad(shape, k)
    grown = np.zeros_like(shape)
    for dy in range(-k, k + 1):
        for dx in range(-k, k + 1):
            w = np.clip(radius + 0.5 - np.hypot(dx, dy), 0, 1)
            if w > 0:
                grown = np.maximum(grown, pad[k + dy:k + dy + n, k + dx:k + dx + n] * w)
    return np.clip(grown - shape, 0, 1) * 255


def gen_ornaments(n):
    return {
        "Dragon": gen_dragon(n), "DragonHead": gen_dragon_head(n), "Laurel": gen_laurel(n),
        "Crown": gen_crown(n), "Flames": gen_flames(n), "Rays": gen_rays(n),
    }


# --- flight path timer ---------------------------------------------------------
# Drawn in the same -1..1 space; the mounts fly right, the pin points down.

def gen_pin(n):
    """A map pin: a round head with a hole, running down to a point (flight path timer)."""
    c = Canvas(n)
    # teardrop: a circle up top, its sides running down to a point
    cy, r = 0.30, 0.52
    tip = -0.95
    t = np.degrees(np.arcsin(r / (cy - tip)))  # where the sides leave the circle
    side = [polar(r, a) + (0, cy) for a in np.linspace(-t, 180 + t, 64)]
    c.add(sd_polygon(c, np.vstack([side, [(0, tip)]])))
    c.cut(sd_circle(c, (0, cy), 0.21))
    return c.alpha * 255

def gen_gryphon(n):
    """A gryphon flying right, its wings raised (the Alliance's flight path mount)."""
    c = Canvas(n)
    # the far wing, fainter, behind everything
    root2 = np.array((0.02, 0.16))
    for deg, ln, w in ((98, 0.70, 0.15), (108, 0.70, 0.15), (118, 0.66, 0.14), (129, 0.58, 0.13)):
        c.add(sd_polygon(c, leaf(root2 + polar(0.05, deg), deg, ln, w)), 0.55)
    # body: a deep eagle chest at the front (right), lion haunches behind
    body = spline([(-0.58, 0.02), (-0.30, 0.12), (0.05, 0.16), (0.30, 0.22), (0.46, 0.16),
                   (0.48, -0.04), (0.30, -0.22), (0.00, -0.26), (-0.34, -0.24), (-0.58, -0.14), (-0.58, 0.02)], 220)
    c.add(sd_polygon(c, body))
    # a big feathered head on a short neck, the beak hooked down
    head = spline([(0.34, 0.18), (0.44, 0.40), (0.60, 0.48), (0.74, 0.44), (0.82, 0.36),
                   (0.80, 0.24), (0.66, 0.18), (0.52, 0.08), (0.34, 0.18)], 160)
    c.add(sd_polygon(c, head))
    beak = bezier([(0.78, 0.42), (0.92, 0.42), (0.98, 0.32), (0.92, 0.22)], 24)
    c.add(sd_polygon(c, np.vstack([beak, [(0.88, 0.27), (0.76, 0.26)]])))
    for p, deg in (((0.44, 0.40), 160), ((0.40, 0.30), 190)):
        c.add(sd_polygon(c, spike(p, deg, 0.13, 0.08, bend=0.2)))           # feather tufts
    c.cut(sd_circle(c, (0.70, 0.37), 0.032))                                # eye
    # the near wing raised high: long feathers fanning up and back over a broad base
    root = np.array((0.00, 0.12))
    for deg, ln, w in ((92, 0.86, 0.17), (102, 0.88, 0.17), (113, 0.86, 0.16), (124, 0.80, 0.16),
                       (136, 0.72, 0.15), (149, 0.62, 0.14), (162, 0.50, 0.13)):
        c.add(sd_polygon(c, leaf(root + polar(0.06, deg), deg, ln, w)))
    c.add(sd_polygon(c, leaf(root + (-0.06, 0), 112, 0.52, 0.36)))
    # eagle talons reaching ahead, a lion leg behind, the tail with its tuft
    c.add(sd_stroke(c, bezier([(0.34, -0.14), (0.50, -0.32), (0.66, -0.30)], 24), 0.06, 0.03))
    c.add(sd_stroke(c, bezier([(0.18, -0.20), (0.30, -0.42), (0.46, -0.44)], 24), 0.06, 0.03))
    c.add(sd_stroke(c, bezier([(-0.42, -0.16), (-0.52, -0.38), (-0.40, -0.50)], 24), 0.09, 0.035))
    c.add(sd_stroke(c, bezier([(-0.56, -0.04), (-0.76, -0.08), (-0.86, 0.06)], 32), 0.035, 0.022))
    c.add(sd_polygon(c, leaf((-0.86, 0.04), 110, 0.20, 0.13)))
    return c.alpha * 255

def gen_wyvern(n):
    """A wind rider flying right, bat wings raised, its scorpion tail curled (the Horde's)."""
    c = Canvas(n)
    body = spline([(-0.40, -0.02), (-0.10, 0.08), (0.25, 0.08), (0.42, 0.02), (0.30, -0.14),
                   (-0.05, -0.20), (-0.36, -0.14), (-0.40, -0.02)], 200)
    c.add(sd_polygon(c, body))
    # a long neck reaching forward, a maned head
    c.add(sd_stroke(c, bezier([(0.30, -0.02), (0.52, 0.10), (0.62, 0.22)], 24), 0.11, 0.08))
    head = spline([(0.54, 0.22), (0.62, 0.34), (0.76, 0.34), (0.92, 0.24), (0.86, 0.16),
                   (0.72, 0.15), (0.60, 0.12), (0.54, 0.22)], 120)
    c.add(sd_polygon(c, head))
    for p, deg in (((0.58, 0.32), 140), ((0.52, 0.26), 160), ((0.48, 0.18), 175)):
        c.add(sd_polygon(c, spike(p, deg, 0.14, 0.06, bend=0.2)))            # mane
    c.add(sd_polygon(c, spike((0.66, 0.34), 105, 0.12, 0.05, bend=0.2)))     # horn
    c.cut(sd_circle(c, (0.74, 0.27), 0.026))
    # a bat wing: arm up to the wrist, fingers spread, membrane scalloped between them
    S, W = np.array((0.02, 0.08)), np.array((-0.10, 0.62))
    tips = [np.array(p) for p in ((0.10, 0.96), (-0.30, 0.92), (-0.58, 0.70), (-0.70, 0.34))]
    root = np.array((-0.30, 0.02))
    edge = [S, W, tips[0]]
    for a, b in zip(tips, tips[1:] + [root]):
        ctrl = (a + b) / 2 + (W - (a + b) / 2) * 0.35
        edge.extend(bezier([a, ctrl, b], 16)[1:])
    c.add(sd_polygon(c, np.vstack(edge)), 0.75)
    c.add(sd_stroke(c, bezier([S, (0.04, 0.38), W], 24), 0.045, 0.03))
    for tip in tips:
        c.add(sd_stroke(c, [W, tip], 0.026, 0.008))
    # legs and the scorpion tail curling up behind
    c.add(sd_stroke(c, bezier([(0.18, -0.14), (0.26, -0.34), (0.40, -0.38)], 24), 0.05, 0.025))
    c.add(sd_stroke(c, bezier([(-0.22, -0.16), (-0.26, -0.36), (-0.12, -0.42)], 24), 0.06, 0.025))
    tail = spline([(-0.36, -0.06), (-0.62, -0.10), (-0.84, 0.00), (-0.88, 0.20), (-0.76, 0.30)], 120)
    c.add(sd_stroke(c, tail, 0.07, 0.03))
    c.add(sd_polygon(c, spike((-0.76, 0.30), 20, 0.16, 0.10, bend=0.1)))
    return c.alpha * 255

def gen_bird(n):
    """A bird of prey flying right (neutral flight paths)."""
    c = Canvas(n)
    body = spline([(-0.55, 0.00), (-0.20, 0.12), (0.30, 0.14), (0.52, 0.16), (0.66, 0.22),
                   (0.80, 0.16), (0.70, 0.04), (0.50, -0.10), (0.10, -0.20), (-0.30, -0.14), (-0.55, 0.00)], 200)
    c.add(sd_polygon(c, body))
    c.add(sd_polygon(c, spike((0.78, 0.17), -20, 0.12, 0.06, bend=0.3)))
    c.cut(sd_circle(c, (0.66, 0.16), 0.03))
    root = np.array((0.10, 0.06))
    for deg, ln, w in ((100, 0.88, 0.16), (110, 0.88, 0.15), (120, 0.84, 0.15), (131, 0.76, 0.14), (143, 0.66, 0.13)):
        c.add(sd_polygon(c, leaf(root + polar(0.05, deg), deg, ln, w)))
    c.add(sd_polygon(c, leaf(root, 112, 0.46, 0.30)))
    for deg in (172, 182, 192):                                              # tail fan
        c.add(sd_polygon(c, leaf((-0.48, -0.01), deg, 0.40, 0.14)))
    return c.alpha * 255


def gen_flight():
    write_tga(os.path.join(MEDIA, "FlightPin.tga"), 64, 64, gen_pin(64))
    for name, gen in (("Gryphon", gen_gryphon), ("Wyvern", gen_wyvern), ("Bird", gen_bird)):
        write_tga(os.path.join(MEDIA, f"Flight{name}.tga"), 128, 128, gen(128))


# Ring10/20/30: rings whose width is 10, 20 or 30 % of the radius (global cooldown
# ring at the cursor: its swipe, track and the queue window's color)
RINGS = (10, 20, 30)


def gen_rings():
    for pct in RINGS:
        write_tga(os.path.join(MEDIA, f"Ring{pct}.tga"), 128, 128, ring(128, pct / 100))


def ring(n, width):
    """Antialiased alpha of a ring touching the edges of an n x n square, width * radius wide."""
    y, x = np.mgrid[0:n, 0:n] + 0.5
    d = np.hypot(x - n / 2, y - n / 2)
    outer = n / 2 - 1
    inner = outer * (1 - width)
    return np.clip(np.minimum(outer - d, d - inner) + 0.5, 0, 1) * 255


def rounded_square(n, radius):
    """Antialiased alpha of an n x n square whose corners are rounded by radius * n."""
    r = radius * n
    if r < 0.5:
        return np.full((n, n), 255.0)
    y, x = np.mgrid[0:n, 0:n] + 0.5
    # distance past the corner circle's center, per axis (0 along the straight edges)
    dx = np.maximum(np.maximum(r - x, x - (n - r)), 0)
    dy = np.maximum(np.maximum(r - y, y - (n - r)), 0)
    return np.clip(r - np.hypot(dx, dy) + 0.5, 0, 1) * 255


def corner(n):
    """Antialiased alpha of a quarter disc of radius n centered on the top-right corner."""
    row, col = np.mgrid[0:n, 0:n]  # rows bottom-up, as write_tga stores them
    from_top = n - 1 - row + 0.5
    from_right = n - 1 - col + 0.5
    d = np.hypot(from_right, from_top)
    return np.clip(n - d + 0.5, 0, 1) * 255


# --- sounds -----------------------------------------------------------------

def t_axis(seconds):
    return np.arange(int(seconds * RATE)) / RATE


def envelope(t, attack, decay):
    env = np.exp(-t / decay)
    a = int(attack * RATE)
    if a > 0:
        env[:a] *= np.linspace(0, 1, a)
    return env


def place(buf, sound, at):
    start = int(at * RATE)
    end = min(len(buf), start + len(sound))
    buf[start:end] += sound[: end - start]


def finish(buf, name):
    fade = int(0.03 * RATE)
    buf[-fade:] *= np.linspace(1, 0, fade)
    buf = buf / np.max(np.abs(buf)) * 10 ** (-3 / 20)  # peak -3 dBFS
    path = os.path.join(SOUNDS, name)
    sf.write(path, buf.astype(np.float32), RATE, format="OGG", subtype="VORBIS")
    return path


def bell(freq, seconds, decay):
    """Bright bell: harmonic partials, higher ones die faster, a touch of shimmer."""
    t = t_axis(seconds)
    partials = [(1.0, 1.0, 1.0), (2.0, 0.45, 0.6), (3.0, 0.2, 0.4), (4.17, 0.08, 0.3)]
    out = np.zeros_like(t)
    for ratio, amp, decay_scale in partials:
        out += amp * np.sin(2 * np.pi * freq * ratio * t) * envelope(t, 0.003, decay * decay_scale)
    out *= 1 + 0.04 * np.sin(2 * np.pi * 6 * t)  # gentle shimmer
    return out


def chime(base, name):
    buf = np.zeros(int(0.8 * RATE))
    place(buf, bell(base, 0.8, 0.22), 0.0)
    place(buf, 0.85 * bell(base * 1.5, 0.74, 0.26), 0.065)  # a fifth up
    return finish(buf, name)


def gen_chime():
    return chime(1046.5, "CritChime.ogg")  # C6


# Crit streaks of 2, 3 and 4+ raise the crit sound by 2, 4 and 7 semitones.
# The game can't change a sound's pitch, so every sound gets its raised copies.
STREAK_STEPS = ((2, 2), (3, 4), (4, 7))


def streak_pitch(semitones):
    return 2 ** (semitones / 12)


def gen_record(pitch=1.0, name="Record.ogg"):
    # rising major arpeggio C6 E6 G6 C7, the last note rings out
    buf = np.zeros(int(1.2 * RATE))
    notes = (1046.5, 1318.5, 1568.0, 2093.0)
    for i, f in enumerate(notes):
        last = i == len(notes) - 1
        place(buf, (1.0 if last else 0.8) * bell(f * pitch, 1.0 if last else 0.5, 0.35 if last else 0.15), i * 0.09)
    return finish(buf, name)


def gen_proc(pitch=1.0, name="Proc.ogg"):
    t = t_axis(0.45)
    tone = np.sin(2 * np.pi * 1760 * pitch * t) + 0.25 * np.sin(2 * np.pi * 2640 * pitch * t)
    return finish(lowpass(tone * envelope(t, 0.005, 0.13), 5000), name)


def soft_square(freq, t):
    return np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(2 * np.pi * 3 * freq * t) / 3


def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def gen_coin(pitch=1.0, name="CritCoin.ogg"):
    buf = np.zeros(int(0.5 * RATE))
    t1 = t_axis(0.075)
    place(buf, 0.8 * soft_square(988 * pitch, t1) * envelope(t1, 0.002, 0.2), 0.0)
    t2 = t_axis(0.42)
    place(buf, soft_square(1319 * pitch, t2) * envelope(t2, 0.002, 0.12), 0.07)
    return finish(lowpass(buf, 6000), name)


def gen_impact(pitch=1.0, name="CritImpact.ogg"):
    seconds = 0.6
    t = t_axis(seconds)
    rng = np.random.default_rng(7)
    # low thump: sine sweeping 150 -> 50 Hz
    freq = (50 + 100 * np.exp(-t / 0.06)) * pitch
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    thump = np.sin(phase) * envelope(t, 0.002, 0.12)
    # short noise transient
    noise = lowpass(rng.standard_normal(len(t)), 3500) * envelope(t, 0.0005, 0.012) * 2.5
    # bright ring on top
    ring = 0.3 * bell(1760 * pitch, seconds, 0.16)
    return finish(thump + noise + ring, name)


# --- reminder sounds: soft, short and pleasant, made to be heard often --------

def gen_softbell(pitch=1.0, name="ReminderBell.ogg"):
    # one warm bell (G5) that rings out gently
    buf = np.zeros(int(1.2 * RATE))
    place(buf, bell(784 * pitch, 1.2, 0.45), 0.0)
    return finish(lowpass(buf, 4500), name)


def ping(freq, seconds, decay):
    t = t_axis(seconds)
    return (np.sin(2 * np.pi * freq * t) + 0.2 * np.sin(2 * np.pi * 2 * freq * t)) * envelope(t, 0.003, decay)


def gen_doubleping(pitch=1.0, name="ReminderDoublePing.ogg"):
    # two quick soft pings, the second a fourth higher
    buf = np.zeros(int(0.55 * RATE))
    place(buf, 0.8 * ping(1318.5 * pitch, 0.3, 0.07), 0.0)
    place(buf, ping(1760 * pitch, 0.4, 0.1), 0.11)
    return finish(lowpass(buf, 6000), name)


def karplus(freq, seconds, damping=0.996, seed=3):
    """Plucked string (Karplus-Strong): a short noise burst in a tuned, damped delay line."""
    n = int(seconds * RATE)
    period = max(2, int(RATE / freq))
    rng = np.random.default_rng(seed)
    line = list(lowpass(rng.uniform(-1, 1, period), 3000))
    out = np.empty(n)
    for i in range(n):
        j = i % period
        v = line[j]
        out[i] = v
        line[j] = damping * 0.5 * (v + line[(j + 1) % period])
    return out


def gen_pluck(pitch=1.0, name="ReminderPluck.ogg"):
    # a plucked A4 with its fifth right after
    buf = np.zeros(int(0.9 * RATE))
    place(buf, karplus(440 * pitch, 0.9), 0.0)
    place(buf, 0.6 * karplus(659.3 * pitch, 0.8, seed=5), 0.08)
    return finish(lowpass(buf, 5000), name)


def mallet(freq, seconds):
    # wooden bar: fundamental plus the bright 4th partial that dies away fast
    t = t_axis(seconds)
    return np.sin(2 * np.pi * freq * t) * envelope(t, 0.002, 0.18) \
        + 0.35 * np.sin(2 * np.pi * 4 * freq * t) * envelope(t, 0.001, 0.03)


def gen_marimba(pitch=1.0, name="ReminderMarimba.ogg"):
    # C5 then G5
    buf = np.zeros(int(0.75 * RATE))
    place(buf, 0.85 * mallet(523.25 * pitch, 0.6), 0.0)
    place(buf, mallet(784 * pitch, 0.6), 0.12)
    return finish(buf, name)


def gen_glass(pitch=1.0, name="ReminderGlass.ogg"):
    # a struck glass: high tone with its inharmonic partial and a slow shimmer
    t = t_axis(1.0)
    f = 2093 * pitch
    tone = np.sin(2 * np.pi * f * t) + 0.6 * np.sin(2 * np.pi * f * 1.003 * t) \
        + 0.25 * np.sin(2 * np.pi * f * 2.76 * t) * envelope(t, 0.0, 0.15)
    return finish(lowpass(tone * envelope(t, 0.002, 0.35), 7000), name)


def gen_ready(pitch=1.0, name="ReminderReady.ogg"):
    # a quick rising triad (E5 G5 B5), the last note rings a little
    buf = np.zeros(int(0.8 * RATE))
    notes = (659.3, 784, 987.8)
    for i, f in enumerate(notes):
        last = i == len(notes) - 1
        place(buf, (1.0 if last else 0.7) * bell(f * pitch, 0.6 if last else 0.25, 0.25 if last else 0.08), i * 0.07)
    return finish(lowpass(buf, 5000), name)


def knock(freq, seconds, seed):
    t = t_axis(seconds)
    rng = np.random.default_rng(seed)
    body = np.sin(2 * np.pi * freq * t) * envelope(t, 0.0005, 0.03)
    click = lowpass(rng.standard_normal(len(t)), 2500) * envelope(t, 0.0002, 0.004)
    return body + 0.6 * click


def gen_woodblock(pitch=1.0, name="ReminderWoodblock.ogg"):
    # two dry wooden knocks, the second lower
    buf = np.zeros(int(0.35 * RATE))
    place(buf, knock(1200 * pitch, 0.2, 1), 0.0)
    place(buf, 0.8 * knock(900 * pitch, 0.2, 2), 0.09)
    return finish(buf, name)


# --- kill sounds: short and rewarding ---------------------------------------

def gen_kill(pitch=1.0, name="Kill.ogg"):
    # a soft low thump with a bright major chord on top, then a little sparkle
    seconds = 0.9
    buf = np.zeros(int(seconds * RATE))
    t = t_axis(0.25)
    freq = (60 + 90 * np.exp(-t / 0.05)) * pitch
    thump = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * envelope(t, 0.002, 0.08)
    place(buf, 0.7 * thump, 0.0)
    for f, amp in ((523.25, 0.55), (659.3, 0.45), (784, 0.45), (1046.5, 0.35)):  # C5 E5 G5 C6
        place(buf, amp * bell(f * pitch, 0.8, 0.28), 0.01)
    place(buf, 0.25 * ping(2093 * pitch, 0.3, 0.06), 0.12)
    place(buf, 0.2 * ping(2637 * pitch, 0.3, 0.06), 0.17)
    return finish(lowpass(buf, 6500), name)


def gen_xp(pitch=1.0, name="XPSparkle.ogg"):
    # a fast rising sparkle (G5 B5 D6 G6), the top note rings with a shimmer
    buf = np.zeros(int(0.9 * RATE))
    notes = (784, 987.8, 1174.7, 1568)
    for i, f in enumerate(notes):
        last = i == len(notes) - 1
        place(buf, (0.9 if last else 0.6) * ping(f * pitch, 0.7 if last else 0.2, 0.3 if last else 0.06), i * 0.045)
    t = t_axis(0.7)
    shimmer = 0.15 * np.sin(2 * np.pi * 3136 * pitch * t) * envelope(t, 0.02, 0.2) * (1 + np.sin(2 * np.pi * 9 * t))
    place(buf, shimmer, 0.14)
    return finish(lowpass(buf, 7000), name)


EXTRA_SOUNDS = (
    (gen_softbell, "ReminderBell"), (gen_doubleping, "ReminderDoublePing"), (gen_pluck, "ReminderPluck"),
    (gen_marimba, "ReminderMarimba"), (gen_glass, "ReminderGlass"), (gen_ready, "ReminderReady"),
    (gen_woodblock, "ReminderWoodblock"), (gen_kill, "Kill"), (gen_xp, "XPSparkle"),
)


def gen_extras():
    return [gen() for gen, _ in EXTRA_SOUNDS]


def gen_streaks():
    # the chime's raised copies keep their original names (CritStreak2-4.ogg)
    paths = [chime(1046.5 * streak_pitch(st), f"CritStreak{level}.ogg") for level, st in STREAK_STEPS]
    # every sound can be the crit sound, so each gets its raised copies
    for gen, base in ((gen_coin, "CritCoin"), (gen_impact, "CritImpact"), (gen_record, "Record"), (gen_proc, "Proc"),
                      *EXTRA_SOUNDS):
        for level, st in STREAK_STEPS:
            paths.append(gen(streak_pitch(st), f"{base}Streak{level}.ogg"))
    return paths


def main():
    os.makedirs(SOUNDS, exist_ok=True)
    gen_textures()
    for path in (gen_chime(), gen_coin(), gen_impact(), gen_record(), gen_proc(), *gen_extras(), *gen_streaks()):
        data, rate = sf.read(path)
        print(f"{os.path.basename(path)}: {len(data) / rate:.2f}s, {rate} Hz, peak {np.max(np.abs(data)):.2f}")
    print("textures: Gradient.tga, Glow.tga, Corner.tga, Shine.tga, Wings.tga, WingsLeft.tga, "
          "Ornament<Style>(Left).tga, Round00-50.tga, Ring10-30.tga, Flight<Pin|Gryphon|Wyvern|Bird>.tga")


if __name__ == "__main__":
    main()
