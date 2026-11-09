// Draws the PrismLink app icon. Usage: swift Tools/make_icon.swift <output.png>
// The chain is drawn by hand because SF Symbols may not be used in app icons.
import AppKit

let side = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
}

func roundedTriangle(_ a: CGPoint, _ b: CGPoint, _ d: CGPoint, radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
    path.addArc(tangent1End: b, tangent2End: d, radius: radius)
    path.addArc(tangent1End: d, tangent2End: a, radius: radius)
    path.addArc(tangent1End: a, tangent2End: b, radius: radius)
    path.closeSubpath()
    return path
}

// Squircle body on Apple's 824pt icon grid.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 184, cornerHeight: 184, transform: nil)

c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.35))
c.addPath(bodyPath)
c.setFillColor(rgb(0x10162F))
c.fillPath()
c.restoreGState()

c.saveGState()
c.addPath(bodyPath)
c.clip()
c.drawLinearGradient(
    gradient([rgb(0x262F5E), rgb(0x0C1126)], [0, 1]),
    start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
)
c.restoreGState()

// Spectral glass prism.
let apex = CGPoint(x: 512, y: 790)
let left = CGPoint(x: 212, y: 268)
let right = CGPoint(x: 812, y: 268)
let prism = roundedTriangle(apex, right, left, radius: 44)
let center = CGPoint(x: 512, y: 442)

c.saveGState()
c.setShadow(offset: .zero, blur: 70, color: rgb(0x58B7FF, 0.45))
c.addPath(prism)
c.setFillColor(rgb(0x3FA8FF))
c.fillPath()
c.restoreGState()

c.saveGState()
c.addPath(prism)
c.clip()
c.drawLinearGradient(
    gradient(
        [rgb(0x1FA8FF), rgb(0x2EE6D6), rgb(0xFFE85C), rgb(0xFF4FA3), rgb(0xFF7A2E)],
        [0, 0.3, 0.52, 0.76, 1]
    ),
    start: CGPoint(x: 290, y: 560), end: CGPoint(x: 730, y: 390),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// Lit left face and shaded base give the triangle its glass volume.
c.beginPath()
c.move(to: apex)
c.addLine(to: center)
c.addLine(to: left)
c.closePath()
c.setFillColor(rgb(0xFFFFFF, 0.1))
c.fillPath()

c.beginPath()
c.move(to: left)
c.addLine(to: center)
c.addLine(to: right)
c.closePath()
c.setFillColor(rgb(0x0B1030, 0.1))
c.fillPath()

c.setStrokeColor(rgb(0xFFFFFF, 0.5))
c.setLineWidth(5)
for point in [apex, left, right] {
    c.move(to: center)
    c.addLine(to: point)
}
c.strokePath()
c.restoreGState()

// Link badge.
let badgeCenter = CGPoint(x: 752, y: 248)
let badgeRadius: CGFloat = 106
func circle(_ radius: CGFloat) -> CGRect {
    CGRect(x: badgeCenter.x - radius, y: badgeCenter.y - radius, width: radius * 2, height: radius * 2)
}
c.setFillColor(rgb(0x10162F))
c.fillEllipse(in: circle(badgeRadius + 14))
c.setFillColor(rgb(0xFFFFFF))
c.fillEllipse(in: circle(badgeRadius))

c.saveGState()
c.translateBy(x: badgeCenter.x, y: badgeCenter.y)
c.rotate(by: .pi / 4)
c.setStrokeColor(rgb(0x1C2450))
c.setLineWidth(20)
let linkWidth: CGFloat = 92
let linkHeight: CGFloat = 54
for x in [-38 - linkWidth / 2, 38 - linkWidth / 2] {
    let rect = CGRect(x: x, y: -linkHeight / 2, width: linkWidth, height: linkHeight)
    c.addPath(CGPath(roundedRect: rect, cornerWidth: 27, cornerHeight: 27, transform: nil))
    c.strokePath()
}
c.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try rep.representation(using: .png, properties: [:])!.write(to: output)
