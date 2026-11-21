import AppKit
import Foundation
import KidSafeCore
import SwiftUI

/// Message « site bloqué » au centre de l'écran. Sur un site en HTTPS, le navigateur affiche son propre
/// message d'erreur (il ignore la page de Privoxy) : KidSafe explique pourquoi, quel que soit le navigateur.
/// Pas de notification macOS : aucune autorisation à demander, rien de masqué par les réglages d'aperçu
/// ou un mode Concentration, et un clic n'ouvre pas les réglages.
extension AppModel {

    static let notifyPollInterval: TimeInterval = 2

    func setNotifyBlocked(_ on: Bool) {
        guard mutate(apply: false, { $0.notifyBlocked = on }) else { return }
        applyPrivoxyOptions()
        updateBlockNotifier()
    }

    /// Lance ou arrête la lecture du journal selon le réglage.
    func updateBlockNotifier() {
        guard catalog.notifyBlocked, let dir = confDir else {
            notifyTimer?.invalidate(); notifyTimer = nil; blockNotifier = nil
            BlockSplash.shared.close()
            return
        }
        if blockNotifier?.confDir != dir {
            blockNotifier = BlockNotifier(confDir: dir)
            _ = blockNotifier?.poll()   // se place à la fin du journal : rien d'ancien n'est signalé
        }
        if notifyTimer == nil {
            let t = Timer(timeInterval: Self.notifyPollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollBlockedSites() }
            }
            RunLoop.main.add(t, forMode: .common)
            notifyTimer = t
        }
    }

    private func pollBlockedSites() {
        guard catalog.notifyBlocked, let match = blockNotifier?.poll() else { return }
        BlockSplash.shared.show(match)
    }
}

/// Panneau flottant qui ne prend pas le focus du navigateur. Il disparaît au premier clic,
/// n'importe où sur l'écran, ou de lui-même après un moment.
@MainActor
final class BlockSplash {
    static let shared = BlockSplash()
    static let autoClose: TimeInterval = 20

    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var closeTimer: Timer?

    func show(_ match: BlockNotifier.Match) {
        let host = NSHostingView(rootView: BlockSplashView(site: match.site, reason: match.reason))
        let size = host.fittingSize
        let isNew = panel == nil
        let p = panel ?? makePanel()
        panel = p
        p.contentView = host
        // Écran où se trouve la souris, un peu au-dessus du centre.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + f.height * 0.1,
                              width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()
        if isNew {
            p.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        }
        // Premier clic, dans KidSafe ou dans n'importe quelle app : le message disparaît.
        if monitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
                Task { @MainActor in BlockSplash.shared.close() }
            }) { monitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in
                Task { @MainActor in BlockSplash.shared.close() }
                return e
            }) { monitors.append(l) }
        }
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: Self.autoClose, repeats: false) { _ in
            Task { @MainActor in BlockSplash.shared.close() }
        }
    }

    func close() {
        closeTimer?.invalidate(); closeTimer = nil
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: {
            Task { @MainActor in p.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }
}

struct BlockSplashView: View {
    var site: String
    var reason: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(Color.orange.gradient))
            Text(L("splash.title")).font(.title2.weight(.bold))
            Text(site).font(.title3.weight(.semibold)).foregroundStyle(.orange)
                .lineLimit(1).truncationMode(.middle)
            Text(L("splash.reason", reason)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                Text(L("splash.dismiss"))
                Text(L("splash.settingsNote"))
            }
            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.top, 6)
        }
        .padding(.horizontal, 36).padding(.vertical, 28)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}
