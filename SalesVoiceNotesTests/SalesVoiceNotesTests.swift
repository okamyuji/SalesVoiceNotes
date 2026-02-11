@testable import SalesVoiceNotes
import Testing

struct SalesVoiceNotesTests {
    // MARK: - computeEnergyFromSamples

    @Test func computeEnergy_withPositiveSamples_returnsAverage() {
        let samples: [Float] = [0.2, 0.4, 0.6]
        let energy = LiveTranscriptionService.computeEnergyFromSamples(samples)
        #expect(abs(energy - 0.4) < 0.001)
    }

    @Test func computeEnergy_withMixedSamples_returnsAverageAbsoluteValue() {
        let samples: [Float] = [-0.3, 0.3, -0.3, 0.3]
        let energy = LiveTranscriptionService.computeEnergyFromSamples(samples)
        #expect(abs(energy - 0.3) < 0.001)
    }

    @Test func computeEnergy_withEmptySamples_returnsZero() {
        let energy = LiveTranscriptionService.computeEnergyFromSamples([])
        #expect(energy == 0)
    }

    @Test func computeEnergy_withSilence_returnsZero() {
        let samples: [Float] = [0, 0, 0, 0]
        let energy = LiveTranscriptionService.computeEnergyFromSamples(samples)
        #expect(energy == 0)
    }

    // MARK: - classifySpeaker

    @Test func classifySpeaker_highEnergy_returnsSalesperson() {
        let frames = [
            EnergyFrame(start: 0, end: 0.25, energy: 0.01),
            EnergyFrame(start: 0.25, end: 0.5, energy: 0.01),
            EnergyFrame(start: 0.5, end: 0.75, energy: 0.5),
            EnergyFrame(start: 0.75, end: 1.0, energy: 0.5),
            EnergyFrame(start: 1.0, end: 1.25, energy: 0.5)
        ]
        // 高エネルギー区間（voiced平均以上） → 営業
        let speaker = LiveTranscriptionService.classifySpeaker(
            start: 0.75, end: 1.25, energyFrames: frames
        )
        #expect(speaker == "営業")
    }

    @Test func classifySpeaker_lowEnergy_returnsCustomer() {
        let frames = [
            EnergyFrame(start: 0, end: 0.25, energy: 0.5),
            EnergyFrame(start: 0.25, end: 0.5, energy: 0.6),
            EnergyFrame(start: 0.5, end: 0.75, energy: 0.05),
            EnergyFrame(start: 0.75, end: 1.0, energy: 0.04)
        ]
        // 低エネルギー区間 → 顧客
        let speaker = LiveTranscriptionService.classifySpeaker(
            start: 0.5, end: 1.0, energyFrames: frames
        )
        #expect(speaker == "顧客")
    }

    @Test func classifySpeaker_emptyFrames_returnsSalesperson() {
        let speaker = LiveTranscriptionService.classifySpeaker(
            start: 0, end: 1.0, energyFrames: []
        )
        #expect(speaker == "営業")
    }

    // MARK: - mergeAdjacent

    @Test func mergeAdjacent_sameSpeakerCloseInTime_merges() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, speaker: "営業", text: "こんにちは"),
            TranscriptSegment(start: 1.2, end: 2, speaker: "営業", text: "お世話に")
        ]
        let merged = LiveTranscriptionService.mergeAdjacent(
            segments: segments, gapTolerance: 0.6
        )
        #expect(merged.count == 1)
        #expect(merged[0].text == "こんにちはお世話に")
        #expect(merged[0].speaker == "営業")
        #expect(merged[0].start == 0)
        #expect(merged[0].end == 2)
    }

    @Test func mergeAdjacent_differentSpeaker_doesNotMerge() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, speaker: "営業", text: "こんにちは"),
            TranscriptSegment(start: 1.2, end: 2, speaker: "顧客", text: "はい")
        ]
        let merged = LiveTranscriptionService.mergeAdjacent(
            segments: segments, gapTolerance: 0.6
        )
        #expect(merged.count == 2)
    }

    @Test func mergeAdjacent_sameSpeakerLargeGap_doesNotMerge() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, speaker: "営業", text: "こんにちは"),
            TranscriptSegment(start: 2.0, end: 3, speaker: "営業", text: "お世話に")
        ]
        let merged = LiveTranscriptionService.mergeAdjacent(
            segments: segments, gapTolerance: 0.6
        )
        #expect(merged.count == 2)
    }

    @Test func mergeAdjacent_emptyInput_returnsEmpty() {
        let merged = LiveTranscriptionService.mergeAdjacent(
            segments: [], gapTolerance: 0.6
        )
        #expect(merged.isEmpty)
    }

    @Test func mergeAdjacent_volatileSegments_neverMerged() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, speaker: "営業", text: "あ", isVolatile: false),
            TranscriptSegment(start: 1.1, end: 2, speaker: "営業", text: "い", isVolatile: true)
        ]
        let merged = LiveTranscriptionService.mergeAdjacent(
            segments: segments, gapTolerance: 0.6
        )
        #expect(merged.count == 2)
    }

    // MARK: - TranscriptSegment

    @Test func transcriptSegment_isVolatileDefaultsFalse() {
        let segment = TranscriptSegment(
            start: 0, end: 1, speaker: "営業", text: "テスト"
        )
        #expect(segment.isVolatile == false)
    }
}
