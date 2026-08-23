# README artwork

The four SVGs here are generated:

```sh
python3 scripts/make-readme-art.py
```

The wallpaper is ours -- a field of the app's own invader at texture opacity, with a brand-green glow behind the notch -- and every name in them is invented. They are **vector reproductions of the real UI, not screenshots.** Every colour
and the invader sprite are copied from `Sources/AgentPerch/UI/InvaderGlyph.swift`,
so they are accurate — but if the palette or a card layout changes there, change
it in the generator and re-run, or they will quietly drift.

| file | shows |
|---|---|
| `hero.svg` | A product shot: the panel hanging from the notch, over a desktop with the agents it is reporting on |
| `permission-card.svg` | A permission request with the tool, target and diff |
| `question-card.svg` | An `AskUserQuestion` prompt with numbered options |
| `plan-card.svg` | A plan review with headings, numbered steps and the three real choices |

## Replacing them with real screenshots

Preferred, when someone can take them — a real grab shows the actual font
rendering and the panel's real proportions.

`⌘⇧4` then space grabs the panel window. Save as `hero.png` etc. and update the
`<img>` paths in the main README. Keep the generator around anyway: it is the
only place the card layouts are written down outside the SwiftUI code.

For an animated version, `⌘⇧5` records a clip and this converts it:

```sh
ffmpeg -i clip.mov -vf "fps=15,scale=740:-1:flags=lanczos" -loop 0 docs/demo.gif
```

The invader marching is the thing worth showing in motion — it only moves while
a turn is genuinely in flight, which is the app's whole thesis in one animation.
