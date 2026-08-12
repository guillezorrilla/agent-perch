#!/usr/bin/env python3
"""Generates the README artwork as SVG.

These are vector reproductions of the real UI, not screenshots. Every colour and
the invader sprite are copied from Sources/VibeNotch/UI/InvaderGlyph.swift, so if
the palette changes there, change it here and re-run:

    python3 scripts/make-readme-art.py

Screenshots are better when someone can take them; this exists so the README is
not blank in the meantime, and so the card layouts stay documented somewhere that
gets updated with the code.
"""

from pathlib import Path

# --- palette, from InvaderGlyph.swift -------------------------------------
GREEN = "#4ADE80"
AMBER = "#F59E0B"
BLUE = "#60A5FA"
GRAY = "#8E8E93"
CARD = "#1C1C1E"
PANEL = "#151515"
WHITE = "#FFFFFF"
NOTCH = "#000000"

SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, monospace"

# --- the invader, from InvaderGlyph.swift ---------------------------------
REST = [
    "..#.....#..",
    "...#...#...",
    "..#######..",
    ".##.###.##.",
    "###########",
    "#.#######.#",
    "#.#.....#.#",
    "...##.##...",
]
STEP = [
    "..#.....#..",
    "#..#...#..#",
    "#.#######.#",
    "###.###.###",
    "###########",
    ".#########.",
    "..#.....#..",
    ".#.......#.",
]


def invader(x, y, cell, color, frame=REST, opacity=1.0):
    out = []
    for r, row in enumerate(frame):
        for c, ch in enumerate(row):
            if ch == "#":
                out.append(
                    f'<rect x="{x + c * cell:.1f}" y="{y + r * cell:.1f}" '
                    f'width="{cell:.1f}" height="{cell:.1f}" fill="{color}" opacity="{opacity}"/>'
                )
    return "\n".join(out)


def text(x, y, s, size=12, fill=WHITE, weight="400", font=SANS, anchor="start", opacity=1.0):
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return (
        f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" '
        f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}" opacity="{opacity}">{s}</text>'
    )


def rect(x, y, w, h, fill, r=0, opacity=1.0, stroke=None):
    s = f' stroke="{stroke}" stroke-width="1"' if stroke else ""
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" '
        f'fill="{fill}" opacity="{opacity}"{s}/>'
    )


def pill(x, y, label, w=None):
    w = w or (len(label) * 6.6 + 16)
    return (
        rect(x, y, w, 19, "#2C2C2E", r=9.5)
        + text(x + w / 2, y + 13.5, label, size=10, fill="#D1D1D6", anchor="middle")
    ), w


def svg(w, h, body, bg=PANEL, radius=22):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
        f'viewBox="0 0 {w} {h}" role="img">\n'
        f'{rect(0, 0, w, h, bg, r=radius)}\n{body}\n</svg>\n'
    )


# --- pieces ---------------------------------------------------------------

def usage_strip(x, y, w):
    p = [
        text(x, y + 11, "✦", size=12, fill=WHITE),
        text(x + 20, y + 11, "Claude", size=12, fill=GRAY, font=MONO),
        text(x + 84, y + 11, "5h", size=12, fill=GRAY, font=MONO),
        text(x + 108, y + 11, "37%", size=12, fill=GREEN, font=MONO, weight="600"),
        text(x + 142, y + 11, "4h25m", size=12, fill=GRAY, font=MONO),
        text(x + 196, y + 11, "|", size=12, fill="#3A3A3C", font=MONO),
        text(x + 212, y + 11, "7d", size=12, fill=GRAY, font=MONO),
        text(x + 236, y + 11, "48%", size=12, fill=GREEN, font=MONO, weight="600"),
        text(x + 270, y + 11, "4d22h", size=12, fill=GRAY, font=MONO),
        text(x, y + 31, "◆", size=12, fill=WHITE),
        text(x + 20, y + 31, "Codex", size=12, fill=GRAY, font=MONO),
        text(x + 84, y + 31, "7d", size=12, fill=GRAY, font=MONO),
        text(x + 108, y + 31, "2%", size=12, fill=GREEN, font=MONO, weight="600"),
        text(x + 142, y + 31, "5d23h", size=12, fill=GRAY, font=MONO),
        text(x + w - 8, y + 12, "↻", size=15, fill=GRAY, anchor="middle"),
    ]
    return "\n".join(p)


def full_card(x, y, w, title, subtitle, status, status_color, elapsed, meta=None,
              glyph_color=GREEN, frame=REST, terminal="Warp", h=92):
    out = [rect(x, y, w, h, CARD, r=16)]
    out.append(invader(x + 16, y + 22, 2.4, glyph_color, frame))
    tx = x + 56
    out.append(text(tx, y + 28, title, size=14, weight="600"))
    if subtitle:
        out.append(text(tx, y + 47, subtitle, size=11, fill=GRAY))
    sy = y + 66 if subtitle else y + 50
    if status_color == "dot":
        out.append(f'<circle cx="{tx + 3.5}" cy="{sy - 4}" r="3.5" fill="{GRAY}"/>')
        out.append(text(tx + 14, sy, status, size=11, fill=GRAY, font=MONO))
    else:
        out.append(f'<circle cx="{tx + 3.5}" cy="{sy - 4}" r="3.5" fill="{status_color}"/>')
        out.append(text(tx + 14, sy, status, size=11, fill=status_color, font=MONO))
    if meta:
        out.append(text(tx, y + 84, meta, size=11, fill="#6E6E73", font=MONO))
    # trailing pills + elapsed
    px = x + w - 16
    p2, w2 = pill(px - 52, y + 16, terminal)
    p1, w1 = pill(px - 52 - w2 - 6 - 4, y + 16, "Claude")
    out.append(p1)
    out.append(p2)
    out.append(text(x + w - 16, y + 56, elapsed, size=11, fill=GRAY, anchor="end"))
    return "\n".join(out)


def compact_row(x, y, w, title, elapsed, dot=GRAY):
    return "\n".join([
        rect(x, y, w, 36, CARD, r=11, opacity=0.72),
        f'<circle cx="{x + 18}" cy="{y + 18}" r="3.5" fill="{dot}"/>',
        text(x + 32, y + 22, title, size=12, weight="500"),
        pill(x + w - 150, y + 8, "Claude")[0],
        pill(x + w - 92, y + 8, "Warp")[0],
        text(x + w - 14, y + 22, elapsed, size=11, fill=GRAY, anchor="end"),
    ])


def option_row(x, y, w, n, label, desc, accent=BLUE):
    return "\n".join([
        rect(x, y, w, 42, PANEL, r=9),
        text(x + 12, y + 19, f"⌘{n}", size=11, fill=accent, weight="500", font=MONO),
        text(x + 46, y + 18, label, size=12, fill=WHITE, weight="500"),
        text(x + 46, y + 33, desc, size=10, fill=GRAY),
    ])


# --- images ---------------------------------------------------------------

def menu_bar_glyphs(x, y, w):
    """Enough of a macOS menu bar to place the panel, without pretending to be a screenshot."""
    out = []
    out.append(f'<circle cx="{x + 14}" cy="{y + 12}" r="5" fill="#C9C9CE" opacity="0.85"/>')
    out.append(f'<rect x="{x + 12}" y="{y + 3}" width="4" height="5" rx="2" fill="#0B0B12"/>')
    out.append(text(x + 30, y + 16, "Finder", size=11, fill="#D8D8DD", weight="600"))
    out.append(text(x + 78, y + 16, "File", size=11, fill="#B8B8BE"))
    out.append(text(x + 110, y + 16, "Edit", size=11, fill="#B8B8BE"))
    out.append(text(x + 144, y + 16, "View", size=11, fill="#B8B8BE"))
    rx = x + w
    out.append(text(rx - 14, y + 16, "9:41", size=11, fill="#D8D8DD", anchor="end"))
    out.append(f'<rect x="{rx - 70}" y="{y + 6}" width="18" height="10" rx="3" '
               f'fill="none" stroke="#B8B8BE" stroke-width="1.2" opacity="0.9"/>')
    out.append(f'<rect x="{rx - 68}" y="{y + 8}" width="11" height="6" rx="1.5" fill="#B8B8BE"/>')
    for i, r in enumerate([3.5, 6.5, 9.5]):
        out.append(f'<path d="M {rx - 100} {y + 17} a {r} {r} 0 0 1 {r * 2} 0" fill="none" '
                   f'stroke="#B8B8BE" stroke-width="1.3" opacity="{0.45 + i * 0.2}"/>')
    return "\n".join(out)


def hero():
    """The panel where it actually lives: hanging from the notch of a MacBook display."""
    w, h = 1060, 496
    bezel = 11
    sw, sh = w - bezel * 2, h - bezel * 2
    menu_h = 26
    panel_w = 700
    panel_x = (w - panel_w) / 2
    panel_h = 396

    b = []
    b.append('<defs><linearGradient id="wall" x1="0" y1="0" x2="0.65" y2="1">'
             '<stop offset="0%" stop-color="#2E2748"/>'
             '<stop offset="50%" stop-color="#1B1932"/>'
             '<stop offset="100%" stop-color="#0D0C16"/></linearGradient>'
             f'<clipPath id="screen"><rect x="{bezel}" y="{bezel}" width="{sw}" height="{sh}" rx="16"/></clipPath>'
             '</defs>')
    # The lid: bezel, then the display.
    b.append(rect(0, 0, w, h, "#08080A", r=26))
    b.append(rect(bezel, bezel, sw, sh, "url(#wall)", r=16))
    b.append('<g clip-path="url(#screen)">')
    b.append(rect(bezel, bezel, sw, menu_h, "#000000", opacity=0.45))
    b.append(menu_bar_glyphs(bezel + 12, bezel + 4, sw - 24))
    # The panel: flush with the top edge and square there, because it grows out of the notch;
    # rounded only at the bottom. That is how DynamicNotchKit draws it.
    b.append(f'<path d="M {panel_x} {bezel} h {panel_w} v {panel_h - 24} '
             f'a 24 24 0 0 1 -24 24 h {-(panel_w - 48)} a 24 24 0 0 1 -24 -24 Z" fill="#0A0A0A"/>')
    b.append('</g>')
    # A hairline so the panel reads as an object against a dark wallpaper.
    b.append(f'<path d="M {panel_x} {bezel} v {panel_h - 24} a 24 24 0 0 0 24 24 h {panel_w - 48} '
             f'a 24 24 0 0 0 24 -24 v {-(panel_h - 24)}" fill="none" '
             f'stroke="#2A2A2E" stroke-width="1" opacity="0.7"/>')

    inner_x = panel_x + 24
    inner_w = panel_w - 48
    b.append(usage_strip(inner_x, bezel + 42, inner_w))
    y = bezel + 98
    b.append(full_card(inner_x, y, inner_w, "api-gateway", "You: add retries to the client",
                       "Running the test suite", "dot", "<1m",
                       meta="2m 31s \u00b7 154.0k tokens", glyph_color=GREEN, frame=STEP))
    b.append(full_card(inner_x, y + 104, inner_w, "checkout-flow", "You: wire up the webhook",
                       "Needs input \u2014 click to jump", AMBER, "3m",
                       glyph_color=AMBER, frame=REST, h=76))
    b.append(compact_row(inner_x, y + 192, inner_w, "web-dashboard", "12m"))
    b.append(compact_row(inner_x, y + 236, inner_w, "docs-site", "41m"))
    return svg(w, h, "\n".join(b), bg="#000000", radius=26)


def permission_card():
    w, h = 620, 300
    b = [rect(20, 16, w - 40, h - 32, CARD, r=16)]
    b.append(f'<circle cx="42" cy="44" r="3.5" fill="{AMBER}"/>')
    b.append(text(56, 48, "Permission Request", size=11, fill=GRAY, weight="500"))
    b.append(text(38, 78, "⚠︎", size=13, fill=AMBER))
    b.append(text(60, 78, "Write", size=13, fill=AMBER, weight="600"))
    b.append(text(108, 78, "src/config/version.txt", size=12, fill=WHITE, font=MONO))
    b.append(rect(38, 92, w - 76, 44, PANEL, r=9))
    b.append(rect(46, 100, w - 92, 20, "#173D25", r=4))
    b.append(text(54, 114, "+approved", size=11, fill=GREEN, font=MONO))
    b.append(text(54, 132, "+1 −0", size=10, fill=GRAY, font=MONO))
    b.append(option_row(38, 148, w - 76, 1, "Yes", "Just this once", AMBER))
    b.append(option_row(38, 196, w - 76, 2, "Yes, allow all edits this session",
                        "Stops this card coming back", AMBER))
    b.append(rect(38, 244, w - 76, 32, PANEL, r=16))
    b.append(text(w / 2, 265, "Deny ⌘N", size=12, fill=WHITE, weight="500", anchor="middle"))
    return svg(w, h, "\n".join(b), bg="#0B0B0B")


def question_card():
    w, h = 620, 286
    b = [rect(20, 16, w - 40, h - 32, CARD, r=16)]
    b.append(f'<circle cx="42" cy="44" r="3.5" fill="{BLUE}"/>')
    b.append(text(56, 48, "Claude asks", size=11, fill=GRAY, weight="500"))
    b.append(text(38, 76, "Which fruit should I use?", size=13, fill=WHITE, weight="600"))
    for i, (lab, desc) in enumerate([
        ("Apple", "The safe default"),
        ("Banana", "Sweeter, ships sooner"),
        ("Cherry", "Small and fast"),
        ("Date", "Dense, chewy, divisive"),
    ]):
        b.append(option_row(38, 92 + i * 48, w - 76, i + 1, lab, desc, BLUE))
    return svg(w, h, "\n".join(b), bg="#0B0B0B")


def plan_card():
    w, h = 620, 400
    b = [rect(20, 16, w - 40, h - 32, CARD, r=16)]
    b.append(f'<circle cx="42" cy="44" r="3.5" fill="{BLUE}"/>')
    b.append(text(56, 48, "Plan Review", size=11, fill=GRAY, weight="500"))
    b.append(rect(38, 62, w - 76, 158, PANEL, r=9))
    b.append(text(54, 84, "Context", size=13, fill=WHITE, weight="600"))
    b.append(text(54, 104, "The tool has no way to report which version is", size=12, fill="#E5E5EA"))
    b.append(text(54, 120, "installed, so bug reports can't be tied to a build.", size=12, fill="#E5E5EA"))
    b.append(text(54, 146, "Plan", size=13, fill=WHITE, weight="600"))
    for i, line in enumerate([
        "Keep the version in one place: __version__",
        "Add --version to the argparse parser",
        "Assert it exits 0 and prints the version",
    ]):
        b.append(text(54, 166 + i * 18, f"{i + 1}.", size=12, fill=BLUE, weight="500"))
        b.append(text(74, 166 + i * 18, line, size=12, fill="#E5E5EA"))
    for i, (lab, desc) in enumerate([
        ("Yes, and use auto mode", "Claude edits without asking again"),
        ("Yes, manually approve edits", "Every edit still asks first"),
        ("Tell Claude what to change", "Opens the session so you can type feedback"),
    ]):
        b.append(option_row(38, 232 + i * 48, w - 76, i + 1, lab, desc, BLUE))
    return svg(w, h, "\n".join(b), bg="#0B0B0B")


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "docs"
    out.mkdir(exist_ok=True)
    for name, maker in [
        ("hero", hero),
        ("permission-card", permission_card),
        ("question-card", question_card),
        ("plan-card", plan_card),
    ]:
        path = out / f"{name}.svg"
        path.write_text(maker())
        print(f"wrote {path.relative_to(path.parent.parent)}  ({path.stat().st_size:,} bytes)")
