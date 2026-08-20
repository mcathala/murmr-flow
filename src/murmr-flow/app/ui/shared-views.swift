import SwiftUI

/// Small pieces reused across the tabs, so headings and warnings look the same
/// everywhere rather than drifting apart per screen.

struct SectionLabel: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct WarningRow: View {
    let message: String
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A labelled key/value grid, for timings and diagnostics.
struct DetailGrid<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            content
        }
        .font(.caption2)
    }
}

/// Standard padding and width for a tab's contents.
struct TabScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
