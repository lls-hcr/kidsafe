import KidSafeCore
import SwiftUI

/// Mini-fenêtre du moniteur : quelques lignes, sans graphique.
struct MonitorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let c = model.monitorCounters
            row(L("mon.requests"), c.map { formatCount($0.requests) } ?? "—")
            row(L("mon.blocked"), c.map { "\(formatCount($0.blocked))  (\(String(format: "%.1f", locale: Locale(identifier: Localization.currentLanguage), $0.blockedPercent)) %)" } ?? "—")
            row(L("mon.domains"), formatCount(model.domainsOnListsNow))
            let social = model.blockedServicesNow.map(\.name)
            row(L("mon.socialNow"), social.isEmpty ? L("mon.noneShort") : social.joined(separator: ", "))
            if model.catalog.recordsBlocks {
                row(L("mon.last"), model.monitorLastBlock.map {
                    "\($0.host) · \($0.date.formatted(.relative(presentation: .named).locale(Locale(identifier: Localization.currentLanguage))))"
                } ?? L("mon.noneShort"))
            }
            row(L("mon.lists"), model.status.lastApplied.map { formatDate($0, date: .abbreviated, time: .shortened) } ?? "—")
            if let event = model.recentEvents.first {
                // Arrêt inattendu, ouverture au démarrage désactivée… : le parent le voit ici pendant une semaine.
                Label {
                    Text(verbatim: EventLog.describe(event, locale: Locale(identifier: Localization.currentLanguage))
                         + (model.recentEvents.count > 1 ? " " + L("mon.events.more", model.recentEvents.count - 1) : ""))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .padding(.top, 8)
            }
            Divider().padding(.vertical, 8)
            HStack {
                if let since = c?.since {
                    Text(L("mon.since", formatDate(since, date: .omitted, time: .shortened))).font(.caption2).foregroundStyle(.secondary)
                } else if c == nil {
                    Text(L("mon.unavailable")).font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Toggle(L("mon.pin"), isOn: $model.monitorPinned).toggleStyle(.checkbox).font(.caption)
            }
            Button {
                model.openDashboard()
            } label: {
                HStack {
                    Image(systemName: "chart.bar.xaxis")
                    Text(L("mon.details"))
                    if model.monitorBusy { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .padding(.top, 10)
            .disabled(model.monitorBusy)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(verbatim: value).font(.body.monospacedDigit()).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.vertical, 3)
    }
}
