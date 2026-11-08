// Draws the app icon: streams meeting in one. Generated, so the PNGs carry no
// camera metadata and anyone can redraw them.
//
//   swift tools/icon/make-icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// App Store Connect refuses a Mac app without a 512pt @2x icon (ITMS-90236),
// and says so only by email after the upload. The iPad app's icon is the same
// drawing, full-bleed and opaque, since iPadOS rounds the corners itself and
// refuses an icon with an alpha channel.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <AppIcon.appiconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(pixels: Int, fullBleed: Bool = false) -> CGImage {
    let size = CGFloat(pixels)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha = fullBleed ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: alpha.rawValue)!

    // macOS icon grid: an 824-point rounded square centred in 1024. Full
    // bleed, that square fills the image, square-cornered.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    if fullBleed {
        ctx.scaleBy(x: size / 824, y: size / 824)
        ctx.translateBy(x: -100, y: -100)
        ctx.clip(to: tile)
    } else {
        ctx.scaleBy(x: size / 1024, y: size / 1024)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.addPath(tilePath)
        ctx.clip()
    }
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.07, green: 0.10, blue: 0.20, alpha: 1),
        CGColor(srgbRed: 0.12, green: 0.20, blue: 0.36, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // Four streams from the top join and leave as one at the bottom.
    let meet = CGPoint(x: 512, y: 400)
    let colors = [
        CGColor(srgbRed: 0.36, green: 0.78, blue: 0.98, alpha: 1),
        CGColor(srgbRed: 0.45, green: 0.90, blue: 0.75, alpha: 1),
        CGColor(srgbRed: 0.98, green: 0.80, blue: 0.40, alpha: 1),
        CGColor(srgbRed: 0.96, green: 0.52, blue: 0.62, alpha: 1),
    ]
    ctx.setLineCap(.round)
    ctx.setLineWidth(56)
    for (i, color) in colors.enumerated() {
        let x = 260 + CGFloat(i) * 168
        ctx.setStrokeColor(color)
        ctx.move(to: CGPoint(x: x, y: 800))
        ctx.addCurve(to: meet, control1: CGPoint(x: x, y: 560), control2: CGPoint(x: 512, y: 600))
        ctx.strokePath()
    }
    ctx.setStrokeColor(CGColor(srgbRed: 0.95, green: 0.97, blue: 1, alpha: 1))
    ctx.setLineWidth(96)
    ctx.move(to: meet)
    ctx.addLine(to: CGPoint(x: 512, y: 210))
    ctx.strokePath()
    return ctx.makeImage()!
}

/// Image I/O adds an eXIf chunk to every PNG, and Apple's iDOT. The image
/// needs neither, and tools/ci/check-public.sh refuses EXIF in any image, so
/// only the chunks that describe pixels are kept.
func pixelsOnly(_ png: Data) -> Data {
    let keep: Set<String> = ["IHDR", "PLTE", "tRNS", "IDAT", "IEND", "sRGB", "iCCP", "gAMA", "cHRM", "pHYs"]
    var out = Data(png.prefix(8))
    var offset = 8
    while offset + 12 <= png.count {
        let length = png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        let type = String(decoding: png[offset + 4..<offset + 8], as: UTF8.self)
        let end = offset + 12 + length
        if keep.contains(type) { out.append(png[offset..<end]) }
        offset = end
    }
    return out
}

func write(_ image: CGImage, to url: URL) throws {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    try pixelsOnly(data as Data).write(to: url)
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try write(draw(pixels: points * scale), to: output.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
try write(draw(pixels: 1024, fullBleed: true), to: output.appending(path: "icon_ios_1024.png"))
images.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon_ios_1024.png"])
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try (json + Data("\n".utf8)).write(to: output.appending(path: "Contents.json"))
