// ChunkerTests.swift
//
// Exercises Chunker.chunk's windowing/overlap logic directly. Note:
// splitIntoSentences is currently a passthrough (see ChunkAndEmbed.swift) --
// these tests treat each input TranscriptSegment as if it were already a
// sentence, matching that placeholder's actual behavior today. Revisit once
// real sentence splitting (NLTokenizer) is wired in.

import Testing
@testable import ServerSample

struct ChunkerTests {
    private func segment(_ text: String, startMs: Int, endMs: Int) -> TranscriptSegment {
        TranscriptSegment(text: text, startMs: startMs, endMs: endMs)
    }

    @Test("empty input produces no chunks")
    func emptyInput() {
        #expect(Chunker.chunk([]).isEmpty)
    }

    @Test("a single short segment still produces one chunk")
    func singleShortSegment() {
        // Below minChars, but there are no other chunks yet -- the
        // "chunks.isEmpty" fallback in Chunker.chunk ensures a transcript
        // with only a little text still gets at least one chunk.
        let seg = segment(String(repeating: "a", count: 50), startMs: 0, endMs: 1000)
        let chunks = Chunker.chunk([seg])

        #expect(chunks.count == 1)
        #expect(chunks[0].text == seg.text)
        #expect(chunks[0].startMs == 0)
        #expect(chunks[0].endMs == 1000)
    }

    @Test("windowing flushes at targetChars with one-sentence overlap")
    func windowingWithOverlap() {
        // seg1 (100) + seg2 (100) + seg3 (150) = 350 chars, crossing
        // targetChars (320) -- should flush after seg3, carrying seg3 into
        // the next window (the one-sentence overlap).
        let seg1 = segment(String(repeating: "a", count: 100), startMs: 0, endMs: 1000)
        let seg2 = segment(String(repeating: "b", count: 100), startMs: 1000, endMs: 2000)
        let seg3 = segment(String(repeating: "c", count: 150), startMs: 2000, endMs: 3000)
        let seg4 = segment(String(repeating: "d", count: 50), startMs: 3000, endMs: 4000)

        let chunks = Chunker.chunk([seg1, seg2, seg3, seg4])

        #expect(chunks.count == 2)

        // First chunk: seg1 + seg2 + seg3, timestamps span the whole window.
        #expect(chunks[0].startMs == 0)
        #expect(chunks[0].endMs == 3000)
        #expect(chunks[0].text.contains(seg1.text))
        #expect(chunks[0].text.contains(seg3.text))

        // Second chunk: starts from seg3 again (the overlap) through seg4.
        #expect(chunks[1].startMs == 2000)
        #expect(chunks[1].endMs == 4000)
        #expect(chunks[1].text.contains(seg3.text))
        #expect(chunks[1].text.contains(seg4.text))
    }

    @Test("a trailing window below minChars is dropped once chunks already exist")
    func trailingWindowDropped() {
        // seg1 (250) + seg2 (80) = 330 crosses targetChars after seg2,
        // flushing chunk 1 and carrying seg2 into the overlap window
        // (currentLen 80). seg3 ("hi", 2 chars) then brings the trailing
        // window to 82 chars -- under minChars (120) -- so the final
        // `currentLen >= minChars || chunks.isEmpty` check drops it: only
        // seg1+seg2 survive as chunk 1, and seg3 never appears in any chunk.
        // Documents real, current behavior rather than an assumption --
        // worth knowing this trailing-content-loss edge case exists.
        let seg1 = segment(String(repeating: "a", count: 250), startMs: 0, endMs: 1000)
        let seg2 = segment(String(repeating: "b", count: 80), startMs: 1000, endMs: 2000)
        let seg3 = segment("hi", startMs: 2000, endMs: 2100)

        let chunks = Chunker.chunk([seg1, seg2, seg3])

        #expect(chunks.count == 1)
        #expect(chunks[0].startMs == 0)
        #expect(chunks[0].endMs == 2000)
        #expect(!chunks.contains { $0.text.contains("hi") })
    }
}
