// Fond de la fenêtre du .dmg : swift scripts/make-dmg-background.swift <sortie.png> <échelle 1|2>
// Fenêtre 640 × 440 points. Icônes : Yamoxy (170, 200), Applications (470, 200),
// en bas : désinstalleur (110, 372) et mode d'emploi (530, 372).
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "background.png"
let k: CGFloat = args.count > 2 ? CGFloat(Double(args[2]) ?? 1) : 1
let W: CGFloat = 640, H: CGFloat = 440
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(W * k), height: Int(H * k), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: k, y: k)
func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
// Le Finder place l'origine en haut à gauche ; CoreGraphics en bas à gauche.
func y(_ top: CGFloat) -> CGFloat { H - top }

// Fond clair, bandeau bleu pétrole en haut (couleur de l'icône).
ctx.setFillColor(rgb(0xF5F8FA)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
ctx.setFillColor(rgb(0x3D839F)); ctx.fill(CGRect(x: 0, y: y(64), width: W, height: 64))

func text(_ s: String, _ x: CGFloat, _ top: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, center: Bool = true) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    let a = NSAttributedString(string: s, attributes: attrs)
    let sz = a.size()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    a.draw(at: NSPoint(x: center ? x - sz.width / 2 : x, y: y(top) - sz.height))
    NSGraphicsContext.restoreGraphicsState()
}
text("Yamoxy", 320, 13, size: 24, weight: .bold, color: .white)
text("Glissez Yamoxy dans Applications  ·  Drag Yamoxy to Applications", 320, 82, size: 13, weight: .medium,
     color: NSColor(cgColor: rgb(0x2B5F74))!)

// Flèche entre les deux icônes.
let arrowY = y(200)
ctx.setStrokeColor(rgb(0x5A97AF)); ctx.setLineWidth(6); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: 250, y: arrowY)); ctx.addLine(to: CGPoint(x: 374, y: arrowY)); ctx.strokePath()
ctx.setFillColor(rgb(0x5A97AF))
ctx.move(to: CGPoint(x: 396, y: arrowY)); ctx.addLine(to: CGPoint(x: 372, y: arrowY + 15)); ctx.addLine(to: CGPoint(x: 372, y: arrowY - 15))
ctx.closePath(); ctx.fillPath()

// Zone discrète du bas : séparateur fin.
ctx.setStrokeColor(rgb(0x000000, 0.08)); ctx.setLineWidth(1)
ctx.move(to: CGPoint(x: 40, y: y(318))); ctx.addLine(to: CGPoint(x: 600, y: y(318))); ctx.strokePath()

let img = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("OK \(out)")
