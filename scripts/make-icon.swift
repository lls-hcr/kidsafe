// Dessine l'icône de KidSafe (1024 px) : swift scripts/make-icon.swift Resources/AppIcon.png
// Fond bleu pétrole, bouclier blanc à moitié plein (style « shield.lefthalf.filled »).
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

// Fond : carré arrondi macOS (grille 824 px centrée).
let box = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.25))
ctx.addPath(bg); ctx.setFillColor(rgb(0x3D839F)); ctx.fillPath()
ctx.restoreGState()
// Léger relief : un peu plus clair en haut.
ctx.saveGState()
ctx.addPath(bg); ctx.clip()
let shade = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0), rgb(0x000000, 0.08)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(shade, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// Bouclier.
func shield(cx: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let l = cx - w / 2, r = cx + w / 2, bottom = top - h
    p.move(to: CGPoint(x: cx, y: top))
    p.addCurve(to: CGPoint(x: r, y: top - h * 0.14), control1: CGPoint(x: cx + w * 0.22, y: top - h * 0.09), control2: CGPoint(x: r - w * 0.10, y: top - h * 0.10))
    p.addCurve(to: CGPoint(x: cx, y: bottom), control1: CGPoint(x: r + w * 0.01, y: top - h * 0.62), control2: CGPoint(x: cx + w * 0.30, y: bottom + h * 0.10))
    p.addCurve(to: CGPoint(x: l, y: top - h * 0.14), control1: CGPoint(x: cx - w * 0.30, y: bottom + h * 0.10), control2: CGPoint(x: l - w * 0.01, y: top - h * 0.62))
    p.addCurve(to: CGPoint(x: cx, y: top), control1: CGPoint(x: l + w * 0.10, y: top - h * 0.10), control2: CGPoint(x: cx - w * 0.22, y: top - h * 0.09))
    p.closeSubpath()
    return p
}
let cx: CGFloat = 512, top: CGFloat = 712, w: CGFloat = 360, h: CGFloat = 420
let outer = shield(cx: cx, top: top, w: w, h: h)
// Contour + moitié gauche pleine, dans un seul calque pour une seule ombre (pas de liseré).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x0B2E3B, 0.30))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(rgb(0xFFFFFF)); ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.addPath(outer); ctx.setLineWidth(34); ctx.setLineJoin(.round); ctx.strokePath()
ctx.saveGState()
ctx.addPath(outer); ctx.clip()
ctx.fill(CGRect(x: cx - w, y: top - h - 40, width: w + 1, height: h + 80))
ctx.restoreGState()
ctx.endTransparencyLayer()
ctx.restoreGState()

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("OK \(out)")
