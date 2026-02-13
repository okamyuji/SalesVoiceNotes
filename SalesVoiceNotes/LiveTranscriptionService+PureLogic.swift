import Foundation

// MARK: - Pure Logic

extension LiveTranscriptionService {
    struct EnergyFrame: Sendable {
        let start: Double
        let end: Double
        let energy: Float
    }

    nonisolated static func computeEnergyFromSamples<C: Collection>(_ samples: C) -> Float
        where C.Element == Float
    {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples {
            sum += s * s
        }
        return sqrt(sum / Float(samples.count))
    }

    nonisolated static func classifySpeaker(
        start: TimeInterval,
        end: TimeInterval,
        energyFrames: [EnergyFrame]
    ) -> String {
        let relevant = energyFrames.filter { $0.end > start && $0.start < end }
        guard !relevant.isEmpty else { return "話者1" }
        let avg = relevant.reduce(Float(0)) { $0 + $1.energy } / Float(relevant.count)
        return avg >= 0.02 ? "話者1" : "話者2"
    }

    static func mergeAdjacent(
        segments: [TranscriptSegment],
        gapTolerance: TimeInterval
    ) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        merged.reserveCapacity(max(1, segments.count / 2))
        var current = segments[0]

        for seg in segments.dropFirst() {
            let canMerge = !current.isVolatile &&
                !seg.isVolatile &&
                current.speaker == seg.speaker &&
                (seg.start - current.end) <= gapTolerance

            if canMerge {
                current = TranscriptSegment(
                    id: current.id,
                    start: current.start,
                    end: seg.end,
                    speaker: current.speaker,
                    text: current.text + seg.text,
                    isVolatile: false
                )
            } else {
                merged.append(current)
                current = seg
            }
        }

        merged.append(current)
        return merged
    }
}
