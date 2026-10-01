// Renders the app icon into Sources/Reed/Assets.xcassets/AppIcon.appiconset,
// and the same artwork as the ReedMark image shown beside the library title.
// Run via `make icon` (or `swift scripts/make_icon.swift`) — an icon you
// can regenerate beats a binary blob nobody can edit.
//
// The image is a clump of reeds, cream on the app's sage accent: three
// stalks leaning apart, each with a plume, and a couple of blades at the
// base. iOS gets the artwork edge to edge and masks it itself; the Mac
// gets it inside the standard rounded tile, at every size it asks for.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0

func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

/// `ReedStyle.accent`, and a lighter cut of it for the top of the gradient.
let sage = rgb(0.32, 0.42, 0.32)
let sageLight = rgb(0.45, 0.56, 0.43)
let cream = rgb(0.96, 0.93, 0.85)
let creamDim = rgb(0.84, 0.86, 0.74)

struct Point { var x, y: Double }

/// A quadratic curve, `t` from 0 at `start` to 1 at `end`.
struct Curve {
    var start, control, end: Point

    func point(_ t: Double) -> Point {
        let u = 1 - t
        return Point(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }

    func tangent(_ t: Double) -> Point {
        let u = 1 - t
        let dx = 2 * u * (control.x - start.x) + 2 * t * (end.x - control.x)
        let dy = 2 * u * (control.y - start.y) + 2 * t * (end.y - control.y)
        let length = (dx * dx + dy * dy).squareRoot()
        return Point(x: dx / length, y: dy / length)
    }
}

/// A filled ribbon along `curve`, `width(t)` wide at each point. Ends
/// where the width reaches zero come to a point; others are cut square.
func ribbon(_ curve: Curve, upTo end: Double = 1, width: (Double) -> Double, samples: Int = 96) -> CGPath {
    var left: [CGPoint] = [], right: [CGPoint] = []
    for index in 0...samples {
        let t = end * Double(index) / Double(samples)
        let p = curve.point(t), n = curve.tangent(t)
        let half = width(t) / 2
        left.append(CGPoint(x: p.x - n.y * half, y: p.y + n.x * half))
        right.append(CGPoint(x: p.x + n.y * half, y: p.y - n.x * half))
    }
    let path = CGMutablePath()
    path.addLines(between: left + right.reversed())
    path.closeSubpath()
    return path
}

/// Narrows gently from `base` towards a point at the far end.
func stalkWidth(_ base: Double) -> (Double) -> Double {
    { t in base * (1 - 0.45 * t) }
}

/// Rounded at the start, widest around `peak`, drawn out to a point: a
/// plume, or with an early peak, a leaf blade.
func bladeWidth(_ widest: Double, at peak: Double = 0.35) -> (Double) -> Double {
    let power = log(0.5) / log(peak)
    return { t in widest * pow(sin(.pi * pow(t, power)), 0.75) }
}

struct Reed {
    var stalk: Curve
    var width: Double
    /// Where along the stalk the plume starts, and how long it is.
    var plumeStart: Double
    var plumeLength: Double
    var plumeWidth: Double
}

let ground = 190.0
let reeds = [
    Reed(stalk: Curve(start: Point(x: 470, y: ground), control: Point(x: 470, y: 520), end: Point(x: 360, y: 830)),
         width: 26, plumeStart: 0.66, plumeLength: 230, plumeWidth: 70),
    Reed(stalk: Curve(start: Point(x: 520, y: ground), control: Point(x: 525, y: 560), end: Point(x: 560, y: 900)),
         width: 28, plumeStart: 0.68, plumeLength: 250, plumeWidth: 76),
    Reed(stalk: Curve(start: Point(x: 570, y: ground), control: Point(x: 590, y: 470), end: Point(x: 720, y: 740)),
         width: 24, plumeStart: 0.64, plumeLength: 210, plumeWidth: 64),
]

let blades = [
    Curve(start: Point(x: 500, y: ground), control: Point(x: 440, y: 420), end: Point(x: 270, y: 500)),
    Curve(start: Point(x: 540, y: ground), control: Point(x: 620, y: 360), end: Point(x: 780, y: 420)),
]

/// Ripples where the reeds meet the water, which double as lines of text.
let ripples = [
    CGRect(x: 330, y: ground - 14, width: 380, height: 28),
    CGRect(x: 410, y: ground - 74, width: 220, height: 28),
]

func drawArtwork(in context: CGContext) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [sage, sageLight] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: side), options: [])

    for blade in blades {
        context.setFillColor(creamDim)
        context.addPath(ribbon(blade, width: bladeWidth(46, at: 0.3)))
        context.fillPath()
    }

    context.setFillColor(cream)
    for ripple in ripples {
        context.addPath(CGPath(roundedRect: ripple, cornerWidth: ripple.height / 2, cornerHeight: ripple.height / 2, transform: nil))
        context.fillPath()
    }

    for reed in reeds {
        // The stalk stops inside the plume, so its tip never pokes out.
        context.addPath(ribbon(reed.stalk, upTo: reed.plumeStart + 0.05, width: stalkWidth(reed.width)))
        context.fillPath()

        // The plume carries on along the stalk's line from where it starts.
        let from = reed.stalk.point(reed.plumeStart), along = reed.stalk.tangent(reed.plumeStart)
        let tip = Point(x: from.x + along.x * reed.plumeLength, y: from.y + along.y * reed.plumeLength)
        let mid = Point(x: (from.x + tip.x) / 2, y: (from.y + tip.y) / 2)
        context.addPath(ribbon(Curve(start: from, control: mid, end: tip), width: bladeWidth(reed.plumeWidth)))
        context.fillPath()
    }
}

func makeContext(_ pixels: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create the bitmap context") }
    context.interpolationQuality = .high
    return context
}

/// Full bleed: iOS masks the corners itself.
func renderIOS(_ pixels: Int = Int(side)) -> CGImage {
    let context = makeContext(pixels)
    let scale = Double(pixels) / side
    context.scaleBy(x: scale, y: scale)
    drawArtwork(in: context)
    return context.makeImage()!
}

/// The artwork inside the Mac's 824-point tile with its continuous corners,
/// leaving the margin macOS expects around it.
func renderMac(_ pixels: Int) -> CGImage {
    let context = makeContext(pixels)
    let scale = Double(pixels) / side
    context.scaleBy(x: scale, y: scale)
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: rgb(0, 0, 0, 0.3))
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.setFillColor(sage)
    context.fillPath()
    context.restoreGState()
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.clip()
    context.translateBy(x: tile.minX, y: tile.minY)
    context.scaleBy(x: tile.width / side, y: tile.height / side)
    drawArtwork(in: context)
    return context.makeImage()!
}

let catalog = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Sources/Reed/Assets.xcassets")

func write(_ image: CGImage, to name: String, in folder: URL) {
    let output = folder.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("could not open \(output.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output.path)") }
}

func writeContents(_ images: [[String: String]], in folder: URL) throws {
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: folder.appendingPathComponent("Contents.json"))
    print("wrote \(folder.path)")
}

let folder = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

var images: [[String: String]] = [
    ["filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
]
write(renderIOS(), to: "icon-ios-1024.png", in: folder)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-mac-\(points)@\(scale)x.png"
        write(renderMac(points * scale), to: name, in: folder)
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

try writeContents(images, in: folder)

/// The mark is drawn at 34 points; the app rounds its corners.
let markPoints = 34
let markFolder = catalog.appendingPathComponent("ReedMark.imageset")
try FileManager.default.createDirectory(at: markFolder, withIntermediateDirectories: true)
var markImages: [[String: String]] = []
for scale in [1, 2, 3] {
    let name = "reed-mark@\(scale)x.png"
    write(renderIOS(markPoints * scale), to: name, in: markFolder)
    markImages.append(["filename": name, "idiom": "universal", "scale": "\(scale)x"])
}
try writeContents(markImages, in: markFolder)
