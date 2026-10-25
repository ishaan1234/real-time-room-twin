import SwiftUI

/// A progress bar for the work after a room scan. RoomPlan doesn't say how
/// far along its processing is, and building the mesh or the 3D view is one
/// call, so the bar is an estimate: each stage fills its part of the bar
/// quickly at first and then ever more slowly, so it keeps moving without
/// ever claiming to be done. How long a stage took last time, on this phone,
/// sets the pace for the next.
struct ProcessingProgress: View {
    struct Stage {
        let title: String
        /// Names the stage for remembering how long it takes, e.g. "roomplan".
        let key: String
        /// The part of the bar this stage fills, 0...1.
        var range: ClosedRange<Double> = 0...1
        /// Seconds per unit of work until the stage has been timed here.
        let guess: TimeInterval
        /// How much there is to do, e.g. triangles in hundred thousands; 1 if it doesn't vary.
        var work: Double = 1
    }

    let stage: Stage

    var body: some View {
        // A new stage starts its own clock.
        StageBar(stage: stage).id(stage.key)
    }
}

/// Real progress reported by SAM Furniture's upload, segmentation, generation
/// and room-assembly stages.
struct DeterminateProcessingProgress: View {
    let progress: SAMFurnitureProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(progress.title)
                Spacer()
                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            ProgressView(value: progress.fraction)
            Text(progress.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: 280)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StageBar: View {
    let stage: ProcessingProgress.Stage
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { context in
            let fraction = progress(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(stage.title)
                    Spacer()
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
                ProgressView(value: fraction)
            }
        }
        .frame(width: 260)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onDisappear(perform: remember)
    }

    private var expected: TimeInterval {
        let perUnit = UserDefaults.standard.object(forKey: defaultsKey) as? Double ?? stage.guess
        return max(perUnit * stage.work, 0.5)
    }

    private var defaultsKey: String { "processing-time.\(stage.key)" }

    /// The stage's part of the bar is about 86% full at the expected time,
    /// and 98% at twice it.
    private func progress(at date: Date) -> Double {
        let share = 1 - exp(-2 * date.timeIntervalSince(start) / expected)
        return stage.range.lowerBound + (stage.range.upperBound - stage.range.lowerBound) * share
    }

    /// The stage is over: blends how long it took into the next estimate.
    private func remember() {
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0.3 else { return }
        let perUnit = elapsed / max(stage.work, 1e-3)
        let previous = UserDefaults.standard.object(forKey: defaultsKey) as? Double
        UserDefaults.standard.set(previous.map { 0.6 * $0 + 0.4 * perUnit } ?? perUnit, forKey: defaultsKey)
    }
}
