#!/usr/bin/env swift
//
// Draw mark's application and document icons. Run with `just icons`.
//
// Output is committed (`packaging/mark.icns`, `packaging/mark-document.icns`),
// and this generator is committed beside it. An `.icns` is an opaque binary
// blob in a diff; the artwork should still be reviewable and reproducible, and
// a script that draws it is how you get both.
//
// **Pure CoreGraphics, and every glyph is a path.** No font is loaded and no
// external rasterizer is invoked: `2026-08-24-rust-core-swift-appkit-shell`
// already charges this project two toolchains, and artwork is not a good reason
// to charge it a third. Drawing text as paths also means the output does not
// depend on which fonts the building machine happens to have — the same commit
// produces the same pixels anywhere.
//
// Each size is rendered at its true pixel size rather than downscaled from one
// master. A 16 pt icon that is a resampled 1024 pt icon is mush; one drawn at
// 16 pt keeps its strokes.
//
//   swift scripts/make-icons.swift <output-dir>
//
// writes `<output-dir>/mark.iconset/` and `<output-dir>/mark-document.iconset/`.
// `just icons` then runs `iconutil` over both.

import CoreGraphics
import Foundation
import ImageIO

// MARK: - Geometry

/// Apple's icon grid: a 1024 pt canvas with the icon body inset 100 pt on every
/// side, leaving 824 pt for the shape itself. The margin is not padding to be
/// reclaimed — it is where the system draws the icon's shadow, and an icon that
/// fills its canvas sits visibly larger than its neighbours in the Dock.
let canvasUnit: CGFloat = 1024
let bodyInset: CGFloat = 100

/// The rounded-square shape, as a superellipse rather than a rounded rect.
///
/// `|x/a|^n + |y/b|^n = 1` with `n = 5` is the usual approximation of the
/// continuous corner macOS uses. A `CGPath(roundedRect:)` has circular corners,
/// and the difference — the corner meeting the edge abruptly instead of easing
/// into it — is exactly the thing that makes a hand-made icon look hand-made.
///
/// Sampled rather than fitted with beziers: 720 segments across a 1024 pt path
/// is a vertex every ~1.4 pt at the widest, which is well below a pixel once the
/// icon is drawn at any size that ships.
func superellipse(center: CGPoint, a: CGFloat, b: CGFloat, n: CGFloat = 5, samples: Int = 720)
    -> CGPath
{
    let path = CGMutablePath()
    for step in 0...samples {
        let theta = 2 * CGFloat.pi * CGFloat(step) / CGFloat(samples)
        let cosT = cos(theta)
        let sinT = sin(theta)
        // `pow` needs a non-negative base, so the magnitude and the sign are
        // taken separately.
        let x = center.x + a * copysign(pow(abs(cosT), 2 / n), cosT)
        let y = center.y + b * copysign(pow(abs(sinT), 2 / n), sinT)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

/// A filled capital `M`, in the unit square with y increasing downward.
///
/// Twelve points rather than a font: see the header. The proportions are a
/// heavy grotesque — 21% stems and a vertex that stops at 72% rather than
/// reaching the baseline — chosen because thin strokes disappear first when the
/// icon is drawn at 16 pt.
func markdownM(in box: CGRect) -> CGPath {
    let unit: [(CGFloat, CGFloat)] = [
        (0.00, 1.00), (0.00, 0.00), (0.22, 0.00), (0.50, 0.42),
        (0.78, 0.00), (1.00, 0.00), (1.00, 1.00), (0.79, 1.00),
        (0.79, 0.36), (0.50, 0.72), (0.21, 0.36), (0.21, 1.00),
    ]
    let path = CGMutablePath()
    for (index, point) in unit.enumerated() {
        let mapped = CGPoint(
            x: box.minX + point.0 * box.width,
            y: box.minY + point.1 * box.height)
        index == 0 ? path.move(to: mapped) : path.addLine(to: mapped)
    }
    path.closeSubpath()
    return path
}

/// The downward arrow beside the `M`, as a solid triangle.
///
/// A stroked chevron is the prettier shape and the wrong one: at 16 pt its
/// strokes land under a pixel and it reads as a smudge. A filled triangle keeps
/// its silhouette all the way down.
func downArrow(in box: CGRect) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: box.minX, y: box.minY))
    path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
    path.addLine(to: CGPoint(x: box.midX, y: box.maxY))
    path.closeSubpath()
    return path
}

// MARK: - Colour

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let brandTop = srgb(109, 139, 255)
let brandBottom = srgb(50, 69, 199)
let paper = srgb(255, 255, 255)
let paperEdge = srgb(208, 211, 220)
let paperFold = srgb(232, 235, 242)

// MARK: - Drawing

/// One icon, at one pixel size.
///
/// - Parameter draw: called with the context already flipped so that (0, 0) is
///   the **top left** and y increases downward, and with a scale factor mapping
///   the 1024 pt design grid onto `size`. Every measurement below is therefore
///   written in design points regardless of the size being rendered.
func render(size: Int, draw: (CGContext, CGFloat) -> Void) -> CGImage? {
    guard
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }

    // CoreGraphics is y-up; the geometry above is written y-down because that
    // is how the shapes were designed. Flip once here rather than inverting
    // every coordinate.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    draw(context, CGFloat(size) / canvasUnit)
    return context.makeImage()
}

/// The application icon: the brand squircle, with the mark knocked out in white.
func drawAppIcon(_ context: CGContext, scale: CGFloat) {
    context.scaleBy(x: scale, y: scale)

    let body = CGRect(
        x: bodyInset, y: bodyInset,
        width: canvasUnit - 2 * bodyInset,
        height: canvasUnit - 2 * bodyInset)
    let shape = superellipse(
        center: CGPoint(x: body.midX, y: body.midY),
        a: body.width / 2, b: body.height / 2)

    // The shadow the 100 pt margin exists for. Drawn by filling the shape once
    // with the shadow set, then again without it — setting a shadow and
    // clipping in the same pass would clip the shadow away too.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -18), blur: 34,
        color: srgb(0, 0, 0, 0.28))
    context.addPath(shape)
    context.setFillColor(brandBottom)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [brandTop, brandBottom] as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.midX, y: body.minY),
        end: CGPoint(x: body.midX, y: body.maxY),
        options: [])
    context.restoreGState()

    // `M` and arrow, sized as one unit and centred in the body together, so the
    // pair reads as a single mark rather than as two shapes that happen to be
    // near each other.
    let markWidth = body.width * 0.60
    let markHeight = markWidth * 0.52
    let origin = CGPoint(
        x: body.midX - markWidth / 2,
        y: body.midY - markHeight / 2)

    context.setFillColor(paper)
    context.addPath(
        markdownM(
            in: CGRect(
                x: origin.x, y: origin.y,
                width: markWidth * 0.62, height: markHeight)))
    context.fillPath()

    let arrowWidth = markWidth * 0.30
    context.addPath(
        downArrow(
            in: CGRect(
                x: origin.x + markWidth - arrowWidth,
                y: origin.y + markHeight * 0.10,
                width: arrowWidth, height: markHeight * 0.90)))
    context.fillPath()
}

/// The document icon: a page with a folded corner and a brand band.
///
/// The band is what makes this legible at 16 pt. A page carrying a small blue
/// mark and a page carrying nothing are the same handful of pixels; a page with
/// a solid bar across its foot is not.
func drawDocumentIcon(_ context: CGContext, scale: CGFloat) {
    context.scaleBy(x: scale, y: scale)

    // Taller than wide, and narrower than the app icon's body: a document icon
    // that fills the same square as an application icon reads as an application.
    let page = CGRect(x: 190, y: 90, width: 644, height: 844)
    let fold: CGFloat = 210
    let radius: CGFloat = 34

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -14), blur: 26,
        color: srgb(0, 0, 0, 0.24))

    // The page outline with the top-right corner cut away for the fold.
    let outline = CGMutablePath()
    outline.move(to: CGPoint(x: page.minX + radius, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
    outline.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
    outline.addLine(to: CGPoint(x: page.maxX, y: page.maxY - radius))
    outline.addQuadCurve(
        to: CGPoint(x: page.maxX - radius, y: page.maxY),
        control: CGPoint(x: page.maxX, y: page.maxY))
    outline.addLine(to: CGPoint(x: page.minX + radius, y: page.maxY))
    outline.addQuadCurve(
        to: CGPoint(x: page.minX, y: page.maxY - radius),
        control: CGPoint(x: page.minX, y: page.maxY))
    outline.addLine(to: CGPoint(x: page.minX, y: page.minY + radius))
    outline.addQuadCurve(
        to: CGPoint(x: page.minX + radius, y: page.minY),
        control: CGPoint(x: page.minX, y: page.minY))
    outline.closeSubpath()

    context.addPath(outline)
    context.setFillColor(paper)
    context.fillPath()
    context.restoreGState()

    context.addPath(outline)
    context.setStrokeColor(paperEdge)
    context.setLineWidth(6)
    context.strokePath()

    // The folded corner, drawn as the triangle the cut above removed.
    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
    foldPath.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
    foldPath.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
    foldPath.closeSubpath()
    context.addPath(foldPath)
    context.setFillColor(paperFold)
    context.fillPath()
    context.addPath(foldPath)
    context.setStrokeColor(paperEdge)
    context.setLineWidth(6)
    context.strokePath()

    // The band, clipped to the page so its square corners cannot poke out
    // through the page's rounded ones.
    context.saveGState()
    context.addPath(outline)
    context.clip()
    let band = CGRect(
        x: page.minX, y: page.maxY - 300, width: page.width, height: 300)
    context.setFillColor(brandBottom)
    context.fill(band)

    let markWidth = band.width * 0.52
    let markHeight = markWidth * 0.52
    let origin = CGPoint(
        x: band.midX - markWidth / 2,
        y: band.midY - markHeight / 2)

    context.setFillColor(paper)
    context.addPath(
        markdownM(
            in: CGRect(
                x: origin.x, y: origin.y,
                width: markWidth * 0.62, height: markHeight)))
    context.fillPath()

    let arrowWidth = markWidth * 0.30
    context.addPath(
        downArrow(
            in: CGRect(
                x: origin.x + markWidth - arrowWidth,
                y: origin.y + markHeight * 0.10,
                width: arrowWidth, height: markHeight * 0.90)))
    context.fillPath()
    context.restoreGState()
}

// MARK: - Writing an iconset

/// `iconutil`'s expected contents: a nominal point size, a scale, and therefore
/// a pixel size. 16@2x and 32@1x are both 32 px and are both required — the
/// same image written under two names.
let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func writePNG(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil)
    else {
        throw Failure("cannot create a PNG writer for \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("writing \(url.path) failed")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func writeIconset(
    named name: String, into directory: URL, draw: (CGContext, CGFloat) -> Void
) throws {
    let iconset = directory.appendingPathComponent("\(name).iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    // Rendered once per distinct pixel size, not once per entry: 16@2x and
    // 32@1x are the same image, and drawing it twice would be the only way for
    // the two files to disagree.
    var byPixels: [Int: CGImage] = [:]
    for entry in entries where byPixels[entry.pixels] == nil {
        guard let image = render(size: entry.pixels, draw: draw) else {
            throw Failure("rendering \(name) at \(entry.pixels)px failed")
        }
        byPixels[entry.pixels] = image
    }
    for entry in entries {
        try writePNG(
            byPixels[entry.pixels]!,
            to: iconset.appendingPathComponent("\(entry.name).png"))
    }
    print("wrote \(iconset.path) (\(entries.count) images)")
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage: swift scripts/make-icons.swift <output-dir>\n".utf8))
    exit(64)  // EX_USAGE
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)

do {
    try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
    try writeIconset(named: "mark", into: outputDirectory, draw: drawAppIcon)
    try writeIconset(named: "mark-document", into: outputDirectory, draw: drawDocumentIcon)
} catch {
    FileHandle.standardError.write(Data("make-icons.swift: \(error)\n".utf8))
    exit(1)
}
