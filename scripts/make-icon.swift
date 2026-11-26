// Dessine l'icône de Yamoxy (1024 px), avec le gecko de l'app :
//   cat Sources/KidSafeApp/GeckoShape.swift scripts/make-icon.swift | swift - Resources/AppIcon.png
// Fond bleu pétrole, bouclier blanc (blason), gecko bleu dessus.
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
// Bouclier blanc (ombre douce), puis le gecko dans la couleur du fond.
let sh = shield(cx: 512, top: 836, w: 560, h: 650)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x0B2E3B, 0.30))
ctx.addPath(sh); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
let gecko = GeckoShape()
ctx.saveGState()
GeckoShape.place(ctx, in: CGRect(x: 332, y: 262, width: 360, height: 500))
gecko.fill(ctx, color: rgb(0x3D839F))
ctx.setFillColor(rgb(0xFFFFFF)); gecko.fillPupils(ctx)
ctx.restoreGState()

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("OK \(out)")
