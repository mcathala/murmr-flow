import SwiftUI

/// The mark, and the only thing on the panel that reports.
///
/// No spinners, no progress arcs, no generic level bars — sound, work and silence are all
/// said with the same five capsules at `MurmrMark`'s own proportions, so this *is* the logo
/// rather than a drawing that resembles it.
///
/// **Which bars move is the grammar.** Sound moves the inner three, because the stems are
/// the letter and the letter should not wobble while you speak. Work moves all five, as a
/// wave travelling left to right. Once you have seen both you can tell listening from
/// thinking at a glance, without reading a word — which matters, because `dictating` and
/// `working` are a tenth of a second apart and look otherwise alike.
struct MarkBars: View {

    enum Motion: Equatable {
        /// The letter, holding still.
        case still
        /// Sound. The inner three rise toward the stems with the level.
        case level(Float)
        /// Work with no sound behind it — a wave through all five.
        case working
        /// The room went quiet. The inner three fall back into the letter, once, and stay
        /// there. It is what "nothing heard" looks like.
        case settling
    }

    var motion: Motion
    var height: CGFloat = PanelLayout.markHeight
    var tint: Color = Theme.Palette.gold

    /// How far toward the stems each bar reaches at full level. Less toward the middle, so
    /// loud speech keeps a trace of the V in it rather than flattening into a block — a
    /// meter that has stopped saying anything.
    private static let reach: [CGFloat] = [1, 0.9, 0.8, 0.9, 1]
    private static let rest = MurmrMark.relativeHeights

    /// Drives the one-shot settle. Starts raised so there is something to fall from.
    @State private var settled = false

    private var scale: CGFloat { height / MurmrMark.bounds.height }
    private var barWidth: CGFloat { MurmrMark.barWidth * scale }
    private var spacing: CGFloat { (MurmrMark.pitch - MurmrMark.barWidth) * scale }

    var body: some View {
        content.frame(height: height)
    }

    @ViewBuilder
    private var content: some View {
        switch motion {
        case .still:
            bars { Self.rest[$0] * height }

        case .level(let level):
            bars { raised($0, by: CGFloat(AudioLevel.normalised(level))) }
                .animation(.easeOut(duration: 0.08), value: level)

        case .settling:
            bars { raised($0, by: settled ? 0 : 0.85) }
                .onAppear {
                    settled = false
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                        settled = true
                    }
                }

        case .working:
            // A clock rather than a repeating animation, so every bar reads the same time
            // and the wave cannot drift apart across five separate animations.
            TimelineView(.animation) { timeline in
                bars { travelling($0, at: timeline.date.timeIntervalSinceReferenceDate) }
            }
        }
    }

    private func bars(_ height: @escaping (Int) -> CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<Self.rest.count, id: \.self) { index in
                Capsule()
                    .fill(tint)
                    .frame(width: barWidth, height: height(index))
            }
        }
    }

    /// Each bar rises from its resting height toward the full height. The stems rest at
    /// full already, so they have no room to move — which is the rule, not an accident.
    private func raised(_ index: Int, by amount: CGFloat) -> CGFloat {
        let rest = Self.rest[index]
        let room = (1 - rest) * Self.reach[index]
        return height * (rest + room * amount)
    }

    /// A raised cosine sweeping through the bars, one period of 1.25s with each bar 90ms
    /// behind the one to its left.
    private func travelling(_ index: Int, at time: TimeInterval) -> CGFloat {
        let period = 1.25
        let offset = Double(index) * 0.09
        let turn = ((time - offset) / period).truncatingRemainder(dividingBy: 1)
        let amount = (1 - cos(turn * 2 * .pi)) / 2
        return height * (0.28 + 0.72 * CGFloat(amount))
    }
}
