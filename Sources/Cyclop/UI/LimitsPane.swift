import SwiftUI

/// Claude and Codex side by side: how much of the five-hour and the weekly
/// limit is left, and when each fills up again. A gauge reads as fuel — the
/// bar is what remains, not what was spent.
struct LimitsPane: View {
    @ObservedObject var limits: LimitsStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            column(
                name: "Claude",
                snapshot: limits.claude,
                subtitle: limits.claude.updatedAt.map(updatedPhrase)
            )
            column(
                name: "Codex",
                snapshot: limits.codex,
                subtitle: limits.isLoadingCodex && limits.codex.updatedAt == nil
                    ? localized("Loading…")
                    : limits.codex.plan
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
    }

    private func column(name: String, snapshot: LimitsStore.Snapshot, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }

            if snapshot.session == nil, snapshot.week == nil {
                Text(snapshot.failure ?? localized("No data yet"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let session = snapshot.session {
                    row(label: localized("5 hours"), window: session.current(at: limits.now))
                }
                if let week = snapshot.week {
                    row(label: localized("Week"), window: week.current(at: limits.now))
                }
                if let failure = snapshot.failure {
                    Text(failure)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func row(label: String, window: LimitsStore.Window) -> some View {
        let remaining = window.remainingPercent
        let low = remaining <= 10
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Spacer(minLength: 4)
                Text("\(remaining)%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(low ? Color.orange : .white)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surfaceHover)
                    Capsule()
                        .fill(low ? Color.orange : Color.white.opacity(0.9))
                        .frame(width: geo.size.width * CGFloat(remaining) / 100)
                }
            }
            .frame(height: 4)
            Text(resetPhrase(window.resetsAt))
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: - Wording

    private func resetPhrase(_ date: Date?) -> String {
        guard let date else { return localized("Full") }
        let minutes = Int((date.timeIntervalSince(limits.now) / 60).rounded(.up))
        let phrase: String
        if minutes <= 0 {
            phrase = localized("any moment")
        } else if minutes < 60 {
            phrase = localized("in %d min", minutes)
        } else if minutes < 24 * 60 {
            let hours = minutes / 60, rest = minutes % 60
            phrase = rest == 0 ? localized("in %d h", hours) : localized("in %d h %d min", hours, rest)
        } else {
            let days = minutes / (24 * 60), hours = (minutes / 60) % 24
            phrase = hours == 0 ? localized("in %d d", days) : localized("in %d d %d h", days, hours)
        }
        return localized("Resets %@", phrase)
    }

    private func updatedPhrase(_ date: Date) -> String {
        let minutes = Int(limits.now.timeIntervalSince(date) / 60)
        if minutes < 1 { return localized("just now") }
        if minutes < 60 { return localized("%d min ago", minutes) }
        let hours = minutes / 60
        if hours < 24 { return localized("%d h ago", hours) }
        return localized("%d d ago", hours / 24)
    }
}
