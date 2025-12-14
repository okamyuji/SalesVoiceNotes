import Foundation

struct TranscriptSegment: Identifiable, Hashable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String
    let text: String
}
