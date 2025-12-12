import Foundation

struct TranscriptSegment: Identifiable, Hashable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String   // "営業" or "顧客"
    let text: String
}
