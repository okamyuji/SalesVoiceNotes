import Foundation

// MARK: - Pure Logic (static, テスト可能)

extension LiveTranscriptionService {
    /// サンプル配列の平均絶対値を計算する。
    nonisolated static func computeEnergyFromSamples(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += abs(sample)
        }
        return sum / Float(samples.count)
    }

    /// 時間範囲内のエネルギーフレームをもとに話者を分類する。
    /// 有声フレームの平均エネルギー以上なら「営業」、未満なら「顧客」。
    nonisolated static func classifySpeaker(
        start: TimeInterval,
        end: TimeInterval,
        energyFrames: [EnergyFrame]
    ) -> String {
        guard !energyFrames.isEmpty else { return "営業" }

        let allEnergies = energyFrames.map(\.energy)
        let mean = allEnergies.reduce(0, +) / Float(allEnergies.count)
        let vadThreshold = max(0.008, mean * 1.2)

        let voiced = energyFrames.filter { $0.energy >= vadThreshold }
        let voicedMean = voiced.isEmpty
            ? mean
            : voiced.map(\.energy).reduce(0, +) / Float(voiced.count)

        let nearbyFrames = energyFrames.filter { frame in
            let center = (frame.start + frame.end) / 2
            return center >= start - 0.25 && center <= end + 0.25
        }

        if nearbyFrames.isEmpty {
            let closest = energyFrames.min { lhs, rhs in
                let lhsCenter = (lhs.start + lhs.end) / 2
                let rhsCenter = (rhs.start + rhs.end) / 2
                let mid = (start + end) / 2
                return abs(lhsCenter - mid) < abs(rhsCenter - mid)
            }
            let closestEnergy = closest?.energy ?? 0
            return closestEnergy >= voicedMean ? "営業" : "顧客"
        }

        let avgEnergy = nearbyFrames.map(\.energy).reduce(0, +) / Float(nearbyFrames.count)
        return avgEnergy >= voicedMean ? "営業" : "顧客"
    }

    /// 同一話者の隣接セグメントを結合する。
    nonisolated static func mergeAdjacent(
        segments: [TranscriptSegment],
        gapTolerance: TimeInterval
    ) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        merged.reserveCapacity(segments.count / 2)

        var current = segments[0]

        for segment in segments.dropFirst() {
            let sameSpeaker = segment.speaker == current.speaker
            let closeInTime = (segment.start - current.end) <= gapTolerance

            if sameSpeaker, closeInTime, !current.isVolatile, !segment.isVolatile {
                current = TranscriptSegment(
                    start: current.start, end: segment.end,
                    speaker: current.speaker,
                    text: current.text + segment.text, isVolatile: false
                )
            } else {
                merged.append(current)
                current = segment
            }
        }
        merged.append(current)
        return merged
    }
}
