import SwiftUI

extension Color {
    static let vibeGreen = Color(red: 74 / 255, green: 222 / 255, blue: 128 / 255)
    static let vibeAmber = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
    static let vibeBlue = Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255)
    static let vibeGray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    static let vibeCard = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let vibeBadge = Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
    static let vibePanel = Color(red: 21 / 255, green: 21 / 255, blue: 21 / 255)
}

/// The pixel invader, in the two poses the arcade original alternates between (#53).
///
/// Space Invaders animates its aliens by swapping between two sprites on a fixed beat rather than
/// by moving anything — which is both the authentic reference and the cheapest thing that could
/// work here: one extra grid, one phase toggle, no per-pixel animation and no dependency.
struct InvaderGlyph: View {
    let color: Color
    /// Whether a turn is genuinely in flight behind this glyph — `SessionStatusPresentation`'s
    /// hook-verified answer, never the mtime-derived `.active`/`.idle` that used to read as
    /// "working" (#52). Movement only means something if it means THAT. Defaults to `false`, which
    /// is both a still glyph and — see `body` — no beat scheduled at all.
    var isWorking = false

    /// How long each pose is held. Slow on purpose: `NotchHoverController` polls the cursor every
    /// 0.1s and closes the panel after a two-tick exit grace, and hover is flaky enough already
    /// (#49), so this must not put real work on the main runloop. Two and a half swaps a second
    /// reads as "alive" and costs one tiny `Canvas` redraw each.
    static let beat: TimeInterval = 0.4

    /// The glyph's fixed grid. Both frames below are exactly this size, which is what keeps the
    /// animation from shifting layout: the `Canvas` divides a fixed 11×8 frame by these, so no
    /// pose can change the glyph's bounds or the card's height (#53).
    static let columns = 11
    static let rows = 8

    enum Frame: Equatable {
        /// The pose a still — not working — invader always holds.
        case rest
        case step
    }

    /// Arms down: the sprite this glyph has always drawn, kept as the resting pose so a session
    /// that is not working looks exactly like it did before #53.
    static let restPixels = [
        [false, false, true,  false, false, false, false, false, true,  false, false],
        [false, false, false, true,  false, false, false, true,  false, false, false],
        [false, false, true,  true,  true,  true,  true,  true,  true,  false, false],
        [false, true,  true,  false, true,  true,  true,  false, true,  true,  false],
        [true,  true,  true,  true,  true,  true,  true,  true,  true,  true,  true ],
        [true,  false, true,  true,  true,  true,  true,  true,  true,  false, true ],
        [true,  false, true,  false, false, false, false, false, true,  false, true ],
        [false, false, false, true,  true,  false, true,  true,  false, false, false]
    ]

    /// Arms up: the arcade's second frame for the same alien. Same 11×8 box, every limb moved
    /// within it — that is the whole trick, and why the card cannot jitter.
    static let stepPixels = [
        [false, false, true,  false, false, false, false, false, true,  false, false],
        [true,  false, false, true,  false, false, false, true,  false, false, true ],
        [true,  false, true,  true,  true,  true,  true,  true,  true,  false, true ],
        [true,  true,  true,  false, true,  true,  true,  false, true,  true,  true ],
        [true,  true,  true,  true,  true,  true,  true,  true,  true,  true,  true ],
        [false, true,  true,  true,  true,  true,  true,  true,  true,  true,  false],
        [false, false, true,  false, false, false, false, false, true,  false, false],
        [false, true,  false, false, false, false, false, false, false, true,  false]
    ]

    /// The entire animation, as a pure function of the two things that decide it. A session that
    /// is not working is pinned to `.rest`, so the glyph stops on a real pose rather than wherever
    /// the beat happened to leave it (#53).
    static func frame(isWorking: Bool, phase: Int) -> Frame {
        guard isWorking else { return .rest }
        return phase.isMultiple(of: 2) ? .rest : .step
    }

    /// Which beat an instant falls in. Derived from the clock rather than counted in view state,
    /// so the pose survives the panel being torn down and rebuilt on every expand, and so two
    /// working cards march together instead of each keeping its own count.
    static func phase(at date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / beat).rounded(.down))
    }

    var body: some View {
        // The beat exists only where it is being watched: a glyph that is not working puts no
        // `TimelineView` in the hierarchy at all, and a collapsed panel has no cards to hold one,
        // so "nothing is working" means no timer anywhere — not a timer nobody looks at (#53).
        if isWorking {
            TimelineView(.periodic(from: .now, by: Self.beat)) { context in
                canvas(Self.frame(isWorking: true, phase: Self.phase(at: context.date)))
            }
        } else {
            canvas(.rest)
        }
    }

    private func canvas(_ frame: Frame) -> some View {
        let pixels = frame == .rest ? Self.restPixels : Self.stepPixels
        return Canvas { context, size in
            let pixelWidth = size.width / CGFloat(Self.columns)
            let pixelHeight = size.height / CGFloat(Self.rows)
            for row in pixels.indices {
                for column in pixels[row].indices where pixels[row][column] {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * pixelWidth,
                            y: CGFloat(row) * pixelHeight,
                            width: pixelWidth,
                            height: pixelHeight
                        )),
                        with: .color(color)
                    )
                }
            }
        }
        // Fixed, and the same for both poses — the frame, not the pixels, is what the layout sees.
        .frame(width: CGFloat(Self.columns), height: CGFloat(Self.rows))
        .accessibilityHidden(true)
    }
}
