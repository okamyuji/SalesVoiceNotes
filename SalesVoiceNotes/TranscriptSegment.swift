import Foundation

nonisolated struct TranscriptSegment: Identifiable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String // "営業" or "顧客"
    let text: String
    var isVolatile: Bool = false
}

/// エネルギーフレーム（話者分離用）
nonisolated struct EnergyFrame: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let energy: Float
}
