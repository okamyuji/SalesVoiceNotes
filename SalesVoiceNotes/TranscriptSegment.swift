import Foundation

struct TranscriptSegment: Identifiable, Hashable {
    let id: UUID
    let start: TimeInterval
    let end: TimeInterval
    let speaker: String
    let text: String
    let isVolatile: Bool

    init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        speaker: String,
        text: String,
        isVolatile: Bool = false
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
        self.isVolatile = isVolatile
    }
}
