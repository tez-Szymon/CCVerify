// Draws CCVerify's app icon — a Claude-orange squircle with a white
// verification seal — and writes the .icns. Vector-drawn at every size so the
// 16pt menu-sized rendering stays legible (the scalloped seal edge and the
// inner ring are dropped below 64pt, where they only turn to mush).
//
// Run: Support/Icon/make-icon.sh  (regenerates Support/AppIcon.icns)
import AppKit

// MARK: - Geometry

/// Apple-style continuous-curvature squircle: a superellipse of degree `n`,
/// which tracks the system icon mask far closer than a rounded rect does.
func squircle(in rect: CGRect, degree n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// The scalloped outline of a wax/approval seal: a circle whose radius is
/// modulated by `lobes` cosine bumps.
func rosette(center c: CGPoint, radius r: CGFloat, amplitude: CGFloat, lobes: Int) -> CGPath {
    let path = CGMutablePath()
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let rr = r + amplitude * cos(CGFloat(lobes) * t)
        let p = CGPoint(x: c.x + rr * cos(t), y: c.y + rr * sin(t))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

let orangeTop = CGColor(red: 0.949, green: 0.573, blue: 0.404, alpha: 1)   // #F29267
let orangeBottom = CGColor(red: 0.749, green: 0.322, blue: 0.192, alpha: 1) // #BF5231

func drawIcon(size S: CGFloat, into ctx: CGContext) {
    let detailed = S >= 64

    // The art sits inside the canvas the way system icons do, leaving room
    // for the shadow (~10% per side).
    let inset = S * 0.0977
    let plate = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let body = squircle(in: plate)

    // Plate + drop shadow.
    ctx.saveGState()
    if detailed {
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012),
                      blur: S * 0.03,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    }
    ctx.addPath(body)
    ctx.setFillColor(orangeBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: [orangeTop, orangeBottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])
    // Glass highlight across the top third.
    if detailed {
        let sheen = CGGradient(colorsSpace: space,
                               colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
                                        CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawLinearGradient(sheen,
                               start: CGPoint(x: plate.midX, y: plate.maxY),
                               end: CGPoint(x: plate.midX, y: plate.midY),
                               options: [])
    }
    ctx.restoreGState()

    let c = CGPoint(x: S / 2, y: S / 2)
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    // The seal: scalloped edge plus a hairline ring, or a plain ring when the
    // icon is too small to resolve the scallops.
    ctx.setStrokeColor(white)
    if detailed {
        ctx.addPath(rosette(center: c, radius: S * 0.262, amplitude: S * 0.026, lobes: 10))
        ctx.setLineWidth(S * 0.042)
        ctx.strokePath()
        ctx.addEllipse(in: CGRect(x: c.x - S * 0.198, y: c.y - S * 0.198,
                                  width: S * 0.396, height: S * 0.396))
        ctx.setLineWidth(S * 0.016)
        ctx.strokePath()
    } else {
        ctx.addEllipse(in: CGRect(x: c.x - S * 0.27, y: c.y - S * 0.27,
                                  width: S * 0.54, height: S * 0.54))
        ctx.setLineWidth(S * 0.055)
        ctx.strokePath()
    }

    // Checkmark.
    ctx.setLineWidth(S * (detailed ? 0.068 : 0.085))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: c.x - S * 0.115, y: c.y + S * 0.015))
    ctx.addLine(to: CGPoint(x: c.x - S * 0.025, y: c.y - S * 0.075))
    ctx.addLine(to: CGPoint(x: c.x + S * 0.125, y: c.y + S * 0.09))
    ctx.strokePath()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    gc.cgContext.setAllowsAntialiasing(true)
    drawIcon(size: CGFloat(size), into: gc.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Output

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try png(size: pt * scale).write(to: iconset.appendingPathComponent(name))
    }
}
// A 1024 preview, handy for eyeballing the art on its own.
try png(size: 1024).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon-preview.png"))
print("Wrote \(iconset.path)")
