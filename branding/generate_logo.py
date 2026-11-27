#!/usr/bin/env python3
"""Erzeugt das Kickpilot-Logo (Fußball mit Pilotenschwingen) als SVG.

Ausgabe: icon.svg (quadratisch, transparent) und logo.svg (Icon + Schriftzug).
"""
import math, os

NAVY = "#13203B"
OUT = os.path.dirname(os.path.abspath(__file__))


def pentagon(cx, cy, r, rot):
    return [(cx + r * math.cos(math.radians(rot + 72 * k)),
             cy + r * math.sin(math.radians(rot + 72 * k))) for k in range(5)]


def pts(p):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in p)


def ball(cx, cy, r, uid):
    """Klassischer Fußball (Blick auf ein Fünfeck) mit Kugelschattierung."""
    s = r / 100.0

    def polar(rad, ang):
        return (cx + rad * s * math.cos(math.radians(ang)), cy + rad * s * math.sin(math.radians(ang)))

    angs = [-90 + 72 * k for k in range(5)]
    inner = [polar(31, a) for a in angs]
    shapes, seams = [], []
    for k, a in enumerate(angs):
        q = polar(60, a)
        s_plus, s_minus = polar(80, a + 21), polar(80, a - 21)
        f_plus, f_minus = polar(112, a + 13), polar(112, a - 13)
        shapes.append([q, s_plus, f_plus, f_minus, s_minus])
        seams.append((inner[k], q))
        nxt = angs[(k + 1) % 5]
        seams.append((s_plus, polar(80, nxt - 21)))
    parts = [f'<clipPath id="{uid}clip"><circle cx="{cx}" cy="{cy}" r="{r}"/></clipPath>',
             f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#{uid}ballfill)"/>',
             f'<g clip-path="url(#{uid}clip)" fill="{NAVY}" stroke="{NAVY}" '
             f'stroke-width="{6.5*s:.1f}" stroke-linejoin="round" stroke-linecap="round">',
             f'<polygon points="{pts(inner)}"/>']
    parts += [f'<polygon points="{pts(p)}"/>' for p in shapes]
    parts += [f'<line x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}"/>' for a, b in seams]
    parts.append('</g>')
    parts.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#{uid}shade)"/>')
    hx, hy = polar(40, -130)
    parts.append(f'<ellipse cx="{hx:.1f}" cy="{hy:.1f}" rx="{22*s:.1f}" ry="{11*s:.1f}" '
                 f'transform="rotate(-40 {hx:.1f} {hy:.1f})" fill="#FFFFFF" opacity="0.6"/>')
    parts.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="none" stroke="{NAVY}" stroke-width="{9*s:.1f}"/>')
    return "\n".join(parts)


def wing(cx, cy, r, side, uid, spread=1.0, lift=1.0):
    """Pilotenschwinge mit vier Federn; side = +1 rechts, -1 links."""
    feathers = []
    for i in reversed(range(4)):           # unten zuerst, obere Feder liegt oben
        x0 = r * 0.5
        yt = -66 + i * 36
        h = 36 - i * 2
        tips = [(138, -142), (122, -92), (100, -44), (72, 2)]
        x1, y1 = r + tips[i][0] * spread, tips[i][1] * lift
        mx = (x0 + x1) / 2
        d = (f"M {x0:.1f} {yt:.1f} "
             f"Q {mx:.1f} {yt - 8:.1f} {x1:.1f} {y1:.1f} "
             f"Q {x1 + 8:.1f} {y1 + h*0.35:.1f} {x1 - 22:.1f} {y1 + h:.1f} "
             f"Q {mx + 10:.1f} {yt + h + 12:.1f} {x0:.1f} {yt + h + 8:.1f} Z")
        feathers.append(f'<path d="{d}" fill="url(#{uid}gold{i})"/>')
    tf = f'translate({cx} {cy}) scale({side} 1)'
    return (f'<g transform="{tf}" stroke="{NAVY}" stroke-width="9" stroke-linejoin="round">'
            + "".join(feathers) + '</g>')


def defs(uid, cx, cy, r):
    golds = [("#FFE08A", "#F5A524"), ("#FFD66B", "#EE9420"), ("#FFCB52", "#E5851C"), ("#FFC03D", "#DB7718")]
    g = "".join(
        f'<linearGradient id="{uid}gold{i}" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'
        for i, (a, b) in enumerate(golds))
    return (f'<defs>{g}'
            f'<radialGradient id="{uid}ballfill" cx="{cx - r*0.35}" cy="{cy - r*0.4}" r="{r*1.5}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0" stop-color="#FFFFFF"/><stop offset="0.7" stop-color="#F1F4F9"/>'
            f'<stop offset="1" stop-color="#C9D2E1"/></radialGradient>'
            f'<radialGradient id="{uid}shade" cx="{cx - r*0.3}" cy="{cy - r*0.35}" r="{r*1.45}" gradientUnits="userSpaceOnUse">'
            f'<stop offset="0.55" stop-color="#13203B" stop-opacity="0"/>'
            f'<stop offset="1" stop-color="#13203B" stop-opacity="0.35"/></radialGradient>'
            '</defs>')


def emblem(cx, cy, r, uid, spread=1.0, lift=1.0):
    star_cy = cy - r - 34
    star = pentagon(0, 0, 1, -90)
    # Fünfzackiger Stern über dem Ball (Rangabzeichen)
    spts = []
    for k in range(5):
        a = -90 + 72 * k
        spts.append((cx + 30 * math.cos(math.radians(a)), star_cy + 30 * math.sin(math.radians(a))))
        a2 = a + 36
        spts.append((cx + 13 * math.cos(math.radians(a2)), star_cy + 13 * math.sin(math.radians(a2))))
    return (defs(uid, cx, cy, r)
            + wing(cx, cy, r, -1, uid, spread, lift) + wing(cx, cy, r, 1, uid, spread, lift)
            + ball(cx, cy, r, uid)
            + f'<polygon points="{pts(spts)}" fill="url(#{uid}gold0)" stroke="{NAVY}" '
              f'stroke-width="7" stroke-linejoin="round"/>')


def write(name, w, h, body):
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n'
           f'{body}\n</svg>\n')
    with open(os.path.join(OUT, name), "w") as f:
        f.write(svg)


if __name__ == "__main__":
    # kompakter für quadratische Icons (kleine Darstellungsgrößen in HA)
    write("icon.svg", 512, 512, emblem(256, 295, 112, "i", spread=0.8, lift=1.08))
    for name, kick, pilot in (("logo.svg", NAVY, "#DB7718"), ("dark_logo.svg", "#FFFFFF", "#FFC03D")):
        # CoreSVG ignoriert tspan-Farben, daher zwei Textelemente
        # („Kick“ ist in Avenir Next Heavy 200 pt mit −4 Laufweite 444 px breit).
        font = 'font-family="Avenir Next" font-weight="800" font-size="200" letter-spacing="-4"'
        text = (f'<text x="545" y="338" {font} fill="{kick}">Kick</text>'
                f'<text x="989" y="338" {font} fill="{pilot}">pilot</text>')
        write(name, 1500, 512, emblem(256, 300, 108, "l") + text)
