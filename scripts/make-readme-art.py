#!/usr/bin/env python3
"""Generates the README artwork as SVG.

These are vector reproductions of the real UI, not screenshots. Every colour and
the invader sprite are copied from Sources/AgentPerch/UI/InvaderGlyph.swift, so if
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

def wallpaper_defs():
    """Ours, not a desktop picture: deep indigo, a brand-green glow behind the notch, and a
    faint field of invaders — the app's own motif, at the opacity of a texture."""
    inv = "".join(
        f'<rect x="{c * 3}" y="{r * 3}" width="3" height="3"/>'
        for r, row in enumerate(REST) for c, ch in enumerate(row) if ch == "#"
    )
    return (
        '<defs>'
        '<linearGradient id="sky" x1="0.15" y1="0" x2="0.85" y2="1">'
        '<stop offset="0%" stop-color="#1B1B3A"/><stop offset="45%" stop-color="#141430"/>'
        '<stop offset="100%" stop-color="#08080F"/></linearGradient>'
        '<radialGradient id="glow" cx="0.5" cy="0" r="0.75">'
        '<stop offset="0%" stop-color="#4ADE80" stop-opacity="0.30"/>'
        '<stop offset="55%" stop-color="#2AA5B8" stop-opacity="0.11"/>'
        '<stop offset="100%" stop-color="#4ADE80" stop-opacity="0"/></radialGradient>'
        '<radialGradient id="corner" cx="0.08" cy="1" r="0.7">'
        '<stop offset="0%" stop-color="#7C5BD6" stop-opacity="0.22"/>'
        '<stop offset="100%" stop-color="#7C5BD6" stop-opacity="0"/></radialGradient>'
        f'<pattern id="invaders" width="120" height="120" patternUnits="userSpaceOnUse">'
        f'<g fill="#8FA0FF" opacity="0.055" transform="translate(18,20)">{inv}</g>'
        f'<g fill="#8FA0FF" opacity="0.045" transform="translate(72,74)">{inv}</g>'
        f'</pattern>'
        '<linearGradient id="win" x1="0" y1="0" x2="0.3" y2="1">'
        '<stop offset="0%" stop-color="#26262C" stop-opacity="0.95"/>'
        '<stop offset="100%" stop-color="#141418" stop-opacity="0.95"/></linearGradient>'
        '<filter id="drop" x="-30%" y="-30%" width="160%" height="190%">'
        '<feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#000" flood-opacity="0.6"/>'
        '</filter>'
        '<filter id="halo" x="-50%" y="-50%" width="200%" height="200%">'
        '<feDropShadow dx="0" dy="0" stdDeviation="26" flood-color="#4ADE80" flood-opacity="0.30"/>'
        '</filter>'
        '</defs>'
    )


def wallpaper(x, y, w, h):
    return "\n".join([
        rect(x, y, w, h, "url(#sky)"),
        rect(x, y, w, h, "url(#invaders)"),
        rect(x, y, w, h, "url(#corner)"),
        rect(x, y, w, h * 0.72, "url(#glow)"),
    ])


def menu_bar(x, y, w):
    out = []
    out.append(f'<circle cx="{x + 14}" cy="{y + 12}" r="5" fill="#E8E8ED" opacity="0.92"/>')
    out.append(f'<rect x="{x + 12}" y="{y + 3}" width="4" height="5" rx="2" fill="#1A1830"/>')
    out.append(text(x + 32, y + 16, "AgentPerch", size="11.5", fill="#F2F2F5", weight="600"))
    # Only what fits clear of the panel: a menu title sliced in half reads as a rendering bug.
    for i, m in enumerate(["File", "Edit"]):
        out.append(text(x + 112 + i * 44, y + 16, m, size="11.5", fill="#DCDCE2"))
    rx = x + w
    out.append(text(rx - 12, y + 16, "Tue 9:41", size="11.5", fill="#F2F2F5", anchor="end"))
    out.append(f'<rect x="{rx - 96}" y="{y + 6}" width="19" height="10" rx="3" fill="none" '
               f'stroke="#E8E8ED" stroke-width="1.2" opacity="0.95"/>')
    out.append(f'<rect x="{rx - 94}" y="{y + 8}" width="13" height="6" rx="1.5" fill="#E8E8ED"/>')
    for i, r in enumerate([3.5, 6.5, 9.5]):
        out.append(f'<path d="M {rx - 130} {y + 17} a {r} {r} 0 0 1 {r * 2} 0" fill="none" '
                   f'stroke="#E8E8ED" stroke-width="1.4" opacity="{0.4 + i * 0.22}"/>')
    return "\n".join(out)


def terminal_window(x, y, w, h, title, lines):
    """A terminal behind the panel: the agents the notch is actually reporting on."""
    out = [f'<g filter="url(#drop)">', rect(x, y, w, h, "url(#win)", r=11), '</g>']
    out.append(rect(x, y, w, 30, "#35353B", r=11, opacity=0.92))
    out.append(rect(x, y + 18, w, 12, "#35353B", opacity=0.92))
    for i, c in enumerate(["#FF5F57", "#FEBC2E", "#28C840"]):
        out.append(f'<circle cx="{x + 17 + i * 17}" cy="{y + 15}" r="5.5" fill="{c}"/>')
    out.append(text(x + w / 2, y + 19, title, size=11, fill="#A9A9B2", font=MONO, anchor="middle"))
    ty = y + 52
    for kind, s in lines:
        if kind == "dot":
            out.append(f'<circle cx="{x + 20}" cy="{ty - 4}" r="3.5" fill="{GREEN}"/>')
            out.append(text(x + 32, ty, s, size=11.5, fill="#E3E3E8", font=MONO))
            ty += 21
        elif kind == "sub":
            out.append(text(x + 44, ty, "└─ " + s, size=11, fill="#8A8A93", font=MONO))
            ty += 22
        else:
            out.append(text(x + 32, ty, s, size=11.5, fill=GREEN, font=MONO))
            ty += 21
    return "\n".join(out)


def mac_frame(panel_h, panel_body, windows, w=1100, h=600, panel_w=640):
    """Every image is the same shot: the panel hanging from the notch of a real screen.

    A card floating on its own never showed WHERE it appears, which is the one thing about
    this app that needs a picture. Sharing the frame also means the four images read as one
    product rather than four unrelated crops.
    """
    bezel = 12
    sw, sh = w - bezel * 2, h - bezel * 2
    panel_x = (w - panel_w) / 2

    b = [wallpaper_defs()]
    b.append(f'<clipPath id="screen"><rect x="{bezel}" y="{bezel}" width="{sw}" '
             f'height="{sh}" rx="18"/></clipPath>')
    b.append(rect(0, 0, w, h, "#0A0A0C", r=30))
    b.append('<g clip-path="url(#screen)">')
    b.append(wallpaper(bezel, bezel, sw, sh))
    b.append(rect(bezel, bezel, sw, 26, "#000000", opacity=0.38))
    b.append(menu_bar(bezel + 14, bezel + 4, sw - 28))
    for win in windows:
        b.append(terminal_window(*win))
    b.append('<g filter="url(#halo)">')
    b.append(f'<path d="M {panel_x} {bezel} h {panel_w} v {panel_h - 26} '
             f'a 26 26 0 0 1 -26 26 h {-(panel_w - 52)} a 26 26 0 0 1 -26 -26 Z" fill="#050505"/>')
    b.append('</g>')
    b.append('</g>')
    b.append(panel_body(panel_x + 20, bezel, panel_w - 40))
    return svg(w, h, "\n".join(b), bg="#000000", radius=30)


WINDOWS = [
    (70, 330, 372, 214, "gemini — web-dashboard", [
        ("dot", "Analyzing the slow queries."),
        ("dot", "Read(schema.prisma)"),
        ("sub", "1.2 KB"),
        ("dot", "Edit(src/db/queries.ts)"),
        ("sub", "Updated (+8 -23)"),
    ]),
    (646, 306, 384, 206, "codex — checkout-flow", [
        ("dot", "Building the REST endpoints."),
        ("dot", "Write(src/routes/users.ts)"),
        ("sub", "New file (47 lines)"),
    ]),
    (330, 392, 430, 190, "claude — api-gateway", [
        ("dot", "Edit(src/auth/middleware.ts)"),
        ("sub", "Updated (+3 -1)"),
        ("dot", "Bash(npm test)"),
        ("sub", "8 passed"),
        ("ok", "All done. 3 files changed."),
    ]),
]

# The lower two windows only, for the taller cards — the panel would cover the rest anyway.
LOW_WINDOWS = [WINDOWS[0], WINDOWS[1]]


def hero():
    def body(x, y, w):
        b = [usage_strip(x, y + 30, w)]
        yy = y + 78
        b.append(full_card(x, yy, w, "api-gateway", "You: fix the auth bug in middleware",
                           "Done — click to jump", GREEN, "28m",
                           glyph_color=GREEN, frame=REST, terminal="iTerm", h=74))
        b.append(compact_row(x, yy + 86, w, "checkout-flow", "1h", dot=BLUE))
        b.append(compact_row(x, yy + 128, w, "web-dashboard", "5h", dot=GREEN))
        return "\n".join(b)
    return mac_frame(262, body, WINDOWS, panel_w=596)


def permission_card():
    def body(x, y, w):
        b = [usage_strip(x, y + 30, w)]
        top = y + 96
        b.append(rect(x, top - 22, w, 268, CARD, r=16))
        b.append(f'<circle cx="{x + 16}" cy="{top}" r="3.5" fill="{AMBER}"/>')
        cx = x + 16
        cw = w - 32
        b.append(text(x + 30, top + 4, "Permission Request", size=11, fill=GRAY, weight="500"))
        b.append(text(cx, top + 34, "⚠︎", size=13, fill=AMBER))
        b.append(text(cx + 22, top + 34, "Write", size=13, fill=AMBER, weight="600"))
        b.append(text(cx + 70, top + 34, "src/config/version.txt", size=12, fill=WHITE, font=MONO))
        b.append(rect(cx, top + 48, cw, 44, PANEL, r=9))
        b.append(rect(cx + 8, top + 56, cw - 16, 20, "#173D25", r=4))
        b.append(text(cx + 16, top + 70, "+approved", size=11, fill=GREEN, font=MONO))
        b.append(text(cx + 16, top + 88, "+1 −0", size=10, fill=GRAY, font=MONO))
        b.append(option_row(cx, top + 102, cw, 1, "Yes", "Just this once", AMBER))
        b.append(option_row(cx, top + 150, cw, 2, "Yes, allow all edits this session",
                            "Stops this card coming back", AMBER))
        b.append(rect(cx, top + 198, cw, 32, PANEL, r=16))
        b.append(text(x + w / 2, top + 219, "Deny ⌘N", size=12, fill=WHITE,
                      weight="500", anchor="middle"))
        return "\n".join(b)
    return mac_frame(366, body, LOW_WINDOWS, panel_w=640, h=620)


def question_card():
    def body(x, y, w):
        b = [usage_strip(x, y + 30, w)]
        top = y + 96
        cx, cw = x + 16, w - 32
        b.append(rect(x, top - 22, w, 224, CARD, r=16))
        b.append(f'<circle cx="{x + 16}" cy="{top}" r="3.5" fill="{BLUE}"/>')
        b.append(text(x + 30, top + 4, "Claude asks", size=11, fill=GRAY, weight="500"))
        b.append(text(cx, top + 32, "Which deployment target?", size=13, fill=WHITE, weight="600"))
        for i, (lab, desc) in enumerate([
            ("Production", "Live traffic, no undo"),
            ("Staging", "Mirrors production, safe to break"),
            ("Local only", "Nothing leaves this machine"),
        ]):
            b.append(option_row(cx, top + 48 + i * 48, cw, i + 1, lab, desc, BLUE))
        return "\n".join(b)
    return mac_frame(322, body, LOW_WINDOWS, panel_w=640)


def plan_card():
    def body(x, y, w):
        b = [usage_strip(x, y + 30, w)]
        top = y + 96
        cx, cw = x + 16, w - 32
        b.append(rect(x, top - 22, w, 358, CARD, r=16))
        b.append(f'<circle cx="{x + 16}" cy="{top}" r="3.5" fill="{BLUE}"/>')
        b.append(text(x + 30, top + 4, "Plan Review", size=11, fill=GRAY, weight="500"))
        b.append(rect(cx, top + 18, cw, 150, PANEL, r=9))
        b.append(text(cx + 16, top + 40, "Context", size=13, fill=WHITE, weight="600"))
        b.append(text(cx + 16, top + 60, "The tool has no way to report which version is",
                      size=12, fill="#E5E5EA"))
        b.append(text(cx + 16, top + 76, "installed, so bug reports can't be tied to a build.",
                      size=12, fill="#E5E5EA"))
        b.append(text(cx + 16, top + 102, "Plan", size=13, fill=WHITE, weight="600"))
        for i, line in enumerate([
            "Keep the version in one place: __version__",
            "Add --version to the argparse parser",
            "Assert it exits 0 and prints the version",
        ]):
            b.append(text(cx + 16, top + 122 + i * 18, f"{i + 1}.", size=12, fill=BLUE, weight="500"))
            b.append(text(cx + 36, top + 122 + i * 18, line, size=12, fill="#E5E5EA"))
        for i, (lab, desc) in enumerate([
            ("Yes, and use auto mode", "Claude edits without asking again"),
            ("Yes, manually approve edits", "Every edit still asks first"),
            ("Tell Claude what to change", "Opens the session so you can type feedback"),
        ]):
            b.append(option_row(cx, top + 182 + i * 48, cw, i + 1, lab, desc, BLUE))
        return "\n".join(b)
    return mac_frame(456, body, LOW_WINDOWS, panel_w=640, h=700)


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
