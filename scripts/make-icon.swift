// Dessine l'icône de KidSafe (1024 px) : swift scripts/make-icon.swift Resources/AppIcon.png
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

// Fond : carré arrondi macOS (grille 824 px centrée), dégradé ciel du matin.
let box = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.28))
ctx.addPath(bg); ctx.setFillColor(rgb(0x3A7BD5)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let sky = CGGradient(colorsSpace: cs, colors: [rgb(0x7FD8F5), rgb(0x3E8EF0), rgb(0x5B4FE0)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// Halo doux en haut à gauche.
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 280, y: 820), startRadius: 0, endCenter: CGPoint(x: 280, y: 820), endRadius: 420, options: [])
ctx.restoreGState()

// Bouclier.
func shield(cx: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let l = cx - w / 2, r = cx + w / 2, bottom = top - h
    p.move(to: CGPoint(x: cx, y: top))
    p.addCurve(to: CGPoint(x: r, y: top - h * 0.12), control1: CGPoint(x: cx + w * 0.2, y: top - h * 0.07), control2: CGPoint(x: r - w * 0.12, y: top - h * 0.06))
    p.addCurve(to: CGPoint(x: cx, y: bottom), control1: CGPoint(x: r + w * 0.02, y: top - h * 0.62), control2: CGPoint(x: cx + w * 0.28, y: bottom + h * 0.12))
    p.addCurve(to: CGPoint(x: l, y: top - h * 0.12), control1: CGPoint(x: cx - w * 0.28, y: bottom + h * 0.12), control2: CGPoint(x: l - w * 0.02, y: top - h * 0.62))
    p.addCurve(to: CGPoint(x: cx, y: top), control1: CGPoint(x: l + w * 0.12, y: top - h * 0.06), control2: CGPoint(x: cx - w * 0.2, y: top - h * 0.07))
    p.closeSubpath()
    return p
}
let outer = shield(cx: 512, top: 800, w: 520, h: 600)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: rgb(0x1B1464, 0.40))
ctx.addPath(outer); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
// Reflet : moitié gauche légèrement teintée.
ctx.saveGState()
ctx.addPath(outer); ctx.clip()
ctx.setFillColor(rgb(0xE8F1FF)); ctx.fill(CGRect(x: 512, y: 150, width: 300, height: 700))
ctx.restoreGState()

// Cœur corail au centre du bouclier.
func heart(cx: CGFloat, cy: CGFloat, s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: cx, y: cy - s * 0.95))
    p.addCurve(to: CGPoint(x: cx - s, y: cy + s * 0.15), control1: CGPoint(x: cx - s * 0.35, y: cy - s * 0.55), control2: CGPoint(x: cx - s, y: cy - s * 0.35))
    p.addCurve(to: CGPoint(x: cx, y: cy + s * 0.55), control1: CGPoint(x: cx - s, y: cy + s * 0.75), control2: CGPoint(x: cx - s * 0.25, y: cy + s * 0.85))
    p.addCurve(to: CGPoint(x: cx + s, y: cy + s * 0.15), control1: CGPoint(x: cx + s * 0.25, y: cy + s * 0.85), control2: CGPoint(x: cx + s, y: cy + s * 0.75))
    p.addCurve(to: CGPoint(x: cx, y: cy - s * 0.95), control1: CGPoint(x: cx + s, y: cy - s * 0.35), control2: CGPoint(x: cx + s * 0.35, y: cy - s * 0.55))
    p.closeSubpath()
    return p
}
let h = heart(cx: 512, cy: 520, s: 150)
ctx.saveGState()
ctx.addPath(h); ctx.clip()
let coral = CGGradient(colorsSpace: cs, colors: [rgb(0xFF8A7A), rgb(0xFF4F6D)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(coral, start: CGPoint(x: 512, y: 690), end: CGPoint(x: 512, y: 370), options: [])
ctx.restoreGState()
// Petit éclat blanc sur le cœur.
ctx.setFillColor(rgb(0xFFFFFF, 0.55))
ctx.fillEllipse(in: CGRect(x: 418, y: 575, width: 52, height: 34))

// Étoile jaune en haut à droite, un peu espiègle.
func star(cx: CGFloat, cy: CGFloat, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for i in 0..<10 {
        let a = CGFloat(i) * .pi / 5 + .pi / 2
        let rr = i % 2 == 0 ? r : r * 0.45
        let pt = CGPoint(x: cx + cos(a) * rr, y: cy + sin(a) * rr)
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x7A4B00, 0.35))
ctx.addPath(star(cx: 770, cy: 770, r: 74)); ctx.setFillColor(rgb(0xFFD23F)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(star(cx: 252, cy: 300, r: 30)); ctx.setFillColor(rgb(0xFFFFFF, 0.8)); ctx.fillPath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("OK \(out)")
