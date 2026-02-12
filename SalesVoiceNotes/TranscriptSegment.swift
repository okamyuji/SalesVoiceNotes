import Foundation

nonisolated struct TranscriptSegment: Identifiable, Sendable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String // "営業" or "顧客"
    let text: String
    let isVolatile: Bool

    init(
        id: UUID = UUID(),
        start: TimeInterval, end: TimeInterval,
        speaker: String, text: String, isVolatile: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.isVolatile = isVolatile
    }
}

/// エネルギーフレーム（話者分離用）
nonisolated struct EnergyFrame: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let energy: Float
}
