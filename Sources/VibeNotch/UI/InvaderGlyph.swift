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

struct InvaderGlyph: View {
    let color: Color

    private static let pixels = [
        [false, false, true,  false, false, false, false, false, true,  false, false],
        [false, false, false, true,  false, false, false, true,  false, false, false],
        [false, false, true,  true,  true,  true,  true,  true,  true,  false, false],
        [false, true,  true,  false, true,  true,  true,  false, true,  true,  false],
        [true,  true,  true,  true,  true,  true,  true,  true,  true,  true,  true ],
        [true,  false, true,  true,  true,  true,  true,  true,  true,  false, true ],
        [true,  false, true,  false, false, false, false, false, true,  false, true ],
        [false, false, false, true,  true,  false, true,  true,  false, false, false]
    ]

    var body: some View {
        Canvas { context, size in
            let pixelWidth = size.width / 11
            let pixelHeight = size.height / 8
            for row in Self.pixels.indices {
                for column in Self.pixels[row].indices where Self.pixels[row][column] {
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
        .frame(width: 11, height: 8)
        .accessibilityHidden(true)
    }
}
