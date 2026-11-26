import AppKit

/// Le gecko de Yamoxy (yamori 家守, « gardien de la maison »), vu de dessus.
/// Dessin vectoriel : cercles balayés le long de la colonne vertébrale, pattes en traits arrondis.
/// Repère de 1000 × 1000, y vers le haut. Aussi utilisé par scripts/make-icon.swift (icône de l'app).
struct GeckoShape {
    /// Épaisseur générale (1 = icône de l'app ; plus épais pour les petites tailles).
    var bold: CGFloat = 1
    /// Doigts par patte (0 : pied rond).
    var toes = 5
    var eyes = true

    struct Leg { var root, joint, foot: CGPoint; var toeAngle: CGFloat }

    /// (x, y, rayon) du museau au bout de la queue.
    static let spine: [(CGFloat, CGFloat, CGFloat)] = [
        (500, 876, 24), (500, 852, 52), (500, 812, 70), (501, 774, 60), (503, 742, 44),
        (505, 706, 52), (507, 654, 64), (505, 594, 70), (498, 534, 66), (490, 484, 54),
        (486, 444, 42), (491, 394, 34), (512, 338, 28), (550, 292, 23), (584, 242, 18),
        (590, 188, 14), (564, 150, 10), (524, 144, 7), (500, 170, 5),
    ]
    static let legs: [Leg] = [
        Leg(root: CGPoint(x: 478, y: 668), joint: CGPoint(x: 395, y: 690), foot: CGPoint(x: 372, y: 768), toeAngle: 112),
        Leg(root: CGPoint(x: 536, y: 658), joint: CGPoint(x: 622, y: 646), foot: CGPoint(x: 660, y: 712), toeAngle: 58),
        Leg(root: CGPoint(x: 464, y: 494), joint: CGPoint(x: 384, y: 512), foot: CGPoint(x: 360, y: 430), toeAngle: 238),
        Leg(root: CGPoint(x: 518, y: 486), joint: CGPoint(x: 604, y: 498), foot: CGPoint(x: 632, y: 426), toeAngle: 302),
    ]
    /// Boîte englobante du dessin (pattes et queue comprises).
    static let bounds = CGRect(x: 300, y: 118, width: 400, height: 776)

    private static func catmull(_ p: [CGPoint], _ t: CGFloat, _ i: Int) -> CGPoint {
        let p0 = p[max(i - 1, 0)], p1 = p[i], p2 = p[min(i + 1, p.count - 1)], p3 = p[min(i + 2, p.count - 1)]
        let t2 = t * t, t3 = t2 * t
        func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y))
    }

    /// Remplit la silhouette de `color`.
    /// `inset` > 0 la rétrécit (pour évider un contour), < 0 l'élargit (pour un liseré).
    func fill(_ ctx: CGContext, color: CGColor, inset d: CGFloat = 0) {
        ctx.saveGState(); defer { ctx.restoreGState() }
        ctx.setFillColor(color); ctx.setStrokeColor(color)
        func dot(_ c: CGPoint, _ r: CGFloat) { if r > 0 { ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) } }
        func line(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat) {
            guard w > 0 else { return }
            ctx.setLineWidth(w); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        }
        let sp = Self.spine, pts = sp.map { CGPoint(x: $0.0, y: $0.1) }, b = bold
        for i in 0..<(pts.count - 1) {
            for k in 0..<24 {
                let t = CGFloat(k) / 24, s = t * t * (3 - 2 * t)
                dot(Self.catmull(pts, t, i), (sp[i].2 * (1 - s) + sp[i + 1].2 * s) * b - d)
            }
        }
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for l in Self.legs {
            line(l.root, l.joint, 44 * b - 2 * d)
            line(l.joint, l.foot, 34 * b - 2 * d)
            if toes == 0 { dot(l.foot, 34 * b - d); continue }
            let spread: CGFloat = toes >= 5 ? 130 : 100, len: CGFloat = toes >= 5 ? 50 : 46
            for k in 0..<toes {
                let a = (l.toeAngle - spread / 2 + spread * CGFloat(k) / CGFloat(max(toes - 1, 1))) * .pi / 180
                let tip = CGPoint(x: l.foot.x + cos(a) * len * b, y: l.foot.y + sin(a) * len * b)
                line(l.foot, tip, 14 * b - 2 * d)
                dot(tip, (toes >= 5 ? 15 : 18) * b - d)
            }
        }
        if eyes { for sx: CGFloat in [-1, 1] { dot(CGPoint(x: 500 + sx * 60 * b, y: 800), 21 * b - d) } }
    }

    /// Pupilles (à dessiner d'une autre couleur par-dessus la silhouette).
    func fillPupils(_ ctx: CGContext) {
        for sx: CGFloat in [-1, 1] {
            let r = 10 * bold
            ctx.fillEllipse(in: CGRect(x: 500 + sx * 64 * bold - r, y: 802 - r, width: 2 * r, height: 2 * r))
        }
    }

    /// Place le repère du gecko dans `rect` (centré, proportions gardées), tourné de `angle` degrés.
    static func place(_ ctx: CGContext, in rect: CGRect, box: CGRect = bounds, angle: CGFloat = 0) {
        let s = min(rect.width / box.width, rect.height / box.height)
        ctx.translateBy(x: rect.midX, y: rect.midY)
        if angle != 0 { ctx.rotate(by: angle * .pi / 180) }
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.midX, y: -box.midY)
    }

    /// Carré qui contient le gecko épais (bold 1,3) tourné de -38° : 569 × 699 autour de (528, 549), avec une petite marge.
    static let symbolBox = CGRect(x: 528 - 360, y: 549 - 360, width: 720, height: 720)

    /// Gecko en diagonale pour les petites tailles (barre des menus, témoin de protection).
    /// Comme WireGuard : net quand le filtrage est actif, estompé (gris) sinon. Image « modèle » :
    /// macOS la colore selon la barre des menus (noir, blanc ou teinte du fond d'écran).
    static func symbol(active: Bool = true, size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            if !active { ctx.setAlpha(inactiveAlpha) }
            place(ctx, in: rect, box: symbolBox, angle: -38)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // une seule opacité pour tout le gecko (pas de chevauchements plus foncés)
            GeckoShape(bold: 1.3, toes: 3, eyes: false).fill(ctx, color: NSColor.black.cgColor)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Opacité du gecko quand le filtrage est désactivé.
    static let inactiveAlpha: CGFloat = 0.35
}
