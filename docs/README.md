# Screenshots for the main README

Drop these five files in here. Sizes are what the README renders them at, so
capture at 2x and let GitHub scale — a retina grab of the panel is ideal.

| file | what to capture |
|---|---|
| `hero.png` | The whole panel, several sessions, at least one working. The banner shot. |
| `panel.png` | Two or three session cards close up — status line, elapsed, tokens, pills. |
| `permission-card.png` | A permission card showing the tool, the target and a diff. |
| `question-card.png` | A question card with its numbered options. |
| `plan-card.png` | A plan review card with headings and numbered steps. |

The demo scripts that stage the last three live in the scratchpad; each one
drives a real session to the prompt so the card is genuine rather than mocked.

Capture with `⌘⇧4` then space to grab the panel window, or `⌘⇧5` for a clip.
For an animated version, record a short `.mov` and convert:

```sh
ffmpeg -i clip.mov -vf "fps=15,scale=720:-1:flags=lanczos" -loop 0 docs/demo.gif
```
