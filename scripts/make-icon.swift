#!/usr/bin/env swift
//
// Builds Support/VibeNotch.icns from a single square source PNG.
//
//   ./scripts/make-icon.swift Support/AppIcon-source.png Support/VibeNotch.icns
//
// Exists because the two things this needs — an alpha-masked rounded rect and a set of
// downscales — are exactly what `sips` cannot do, and pulling in ImageMagick to crop a
// square would be a dependency per icon revision. `iconutil` does the final packing.
//
// The source is expected to be the artwork ALREADY cropped to its own rounded-rect bounds,
// background included. This clips that background away; it does not invent a shape.

import AppKit
import CoreGraphics

// Apple's macOS icon grid: on a 1024pt canvas the shape occupies 824pt centred, with the
// remainder left transparent. Skipping this is why third-party icons sit visibly larger
// than system ones in Finder.
let artworkScale = 824.0 / 1024.0
// 22.37% of the shape's width, Apple's continuous-corner radius. Deliberately a hair wider
// than the source's own corner: clipping slightly INSIDE the artwork removes every trace of
// the original background, where clipping outside it would leave a white rind in each
// corner. The over-cut lands on near-black pixels and is invisible.
let cornerRatio = 0.2337

// Every size macOS asks for. 1024 is an upscale from a 424pt source and looks it under a
// magnifier — it is also the slot almost nobody sees, since LSUIElement means this app has
// no Dock icon at all. Re-run with larger source art to fix it properly.
let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x")
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: make-icon.swift <source.png> <output.icns>")
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = NSImage(contentsOf: sourceURL),
      let sourceImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail("could not read \(sourceURL.path)")
}
guard sourceImage.width == sourceImage.height else {
    fail("source must be square, got \(sourceImage.width)x\(sourceImage.height)")
}

func render(canvas: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: canvas,
        height: canvas,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high

    let artwork = (Double(canvas) * artworkScale).rounded()
    let origin = ((Double(canvas) - artwork) / 2).rounded()
    let rect = CGRect(x: origin, y: origin, width: artwork, height: artwork)

    context.addPath(CGPath(
        roundedRect: rect,
        cornerWidth: artwork * cornerRatio,
        cornerHeight: artwork * cornerRatio,
        transform: nil
    ))
    context.clip()
    context.draw(sourceImage, in: rect)

    return context.makeImage()
}

let iconset = outputURL.deletingLastPathComponent()
    .appendingPathComponent("VibeNotch.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    guard let image = render(canvas: size.px) else { fail("render failed at \(size.px)px") }
    let url = iconset.appendingPathComponent("\(size.name).png")
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil
    ) else { fail("could not write \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not encode \(url.lastPathComponent)") }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

try? FileManager.default.removeItem(at: iconset)
print("wrote \(outputURL.path)")
