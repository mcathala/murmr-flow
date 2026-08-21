import SwiftUI

/// Small pieces reused across the sections, so headings, rows and warnings look the same
/// everywhere rather than drifting apart per screen.

struct SectionLabel: View {
    let title: String
    var icon: String?

    var body: some View {
        Group {
            if let icon {
                Label(title, systemImage: icon)
            } else {
                Text(title)
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }
}

struct WarningRow: View {
    let message: String
    var tint: Color = .orange
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action.title, action: action.run)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 8))
    }
}

/// A labelled key/value grid, for anything tabular.
struct DetailGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            content
        }
        .font(.caption)
    }
}

/// A dot and a word. Green means tested and working — not merely configured.
struct StatusChip: View {
    enum Level {
        case ok, waiting, bad

        var color: Color {
            switch self {
            case .ok: .green
            case .waiting: .secondary
            case .bad: .orange
            }
        }
    }

    let title: String
    var level: Level = .ok

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(level.color).frame(width: 7, height: 7)
            Text(title).font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: .capsule)
    }
}

/// A bordered container. The one box style in the app, so nothing has to decide.
struct Card<Content: View>: View {
    var highlighted = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.28), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                            lineWidth: highlighted ? 1.5 : 0.5)
            }
    }
}

/// One setting: what it is on the left, the control on the right.
///
/// No explanatory caption. If a label needs a paragraph underneath it, the label is wrong
/// — the one exception in the app is the hold-to-talk toggle, where "off" genuinely needs
/// a sentence.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                control
            }
        }
    }
}

/// Standard padding and rhythm for a scrolling pane.
struct PaneScroll<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let title {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .padding(.bottom, 2)
                }
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A big centred prompt for a screen with nothing on it yet. Says what to do, not what
/// is missing.
struct EmptyPane: View {
    let symbol: String
    let title: String
    let hint: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.medium))
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Two letters, not a brand logo.
///
/// A wall of official marks — one orange, one black, one tan, one blue — would fight the
/// app's own palette in a single view, and each one is a trademarked asset to ship and
/// keep current. Monograms cost nothing and stay on-palette. Recognition is the trade.
struct Monogram: View {
    let name: String

    var body: some View {
        Text(initials)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .frame(width: 26, height: 26)
            .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 7))
            .foregroundStyle(.secondary)
    }

    private var initials: String {
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return words.prefix(2).compactMap { $0.first }.map(String.init)
                .joined().lowercased()
        }
        return String(name.prefix(2)).lowercased()
    }
}

/// An app's real icon where we can get it, a monogram where we can't.
///
/// For apps on this Mac the icon is free and always current — macOS resolves it from the
/// bundle identifier. The monogram is the fallback for an app that has since been
/// uninstalled, where a generic placeholder would say less than two letters do.
struct AppBadge: View {
    let name: String
    let bundleID: String?
    var size: CGFloat = 26

    var body: some View {
        if let icon = AppIconCache.icon(forBundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: size, height: size)
                .help(name)
        } else {
            Monogram(name: name)
        }
    }
}
