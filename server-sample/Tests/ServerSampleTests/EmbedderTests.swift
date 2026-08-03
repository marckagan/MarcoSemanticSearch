// EmbedderTests.swift
//
// The "search_document: " prefix is the single most important correctness
// requirement in this design (see PROPOSAL.md's tokenizer-parity note) --
// get it wrong and relevance degrades silently, no crash. This tests the
// pure prefixing logic directly, independent of the (currently
// fatalError-stubbed) real embedding call.

import Testing
@testable import ServerSample

struct EmbedderTests {
    @Test("prefixedForStorage applies the search_document: prefix")
    func appliesPrefix() {
        #expect(Embedder.prefixedForStorage("hello world") == "search_document: hello world")
    }

    @Test("prefixedForStorage uses the declared documentPrefix constant")
    func usesDeclaredConstant() {
        let text = "a transcript chunk with punctuation, and numbers 123."
        #expect(Embedder.prefixedForStorage(text) == Embedder.documentPrefix + text)
    }

    @Test("prefixedForStorage still applies the prefix to an empty string")
    func emptyStringStillPrefixed() {
        #expect(Embedder.prefixedForStorage("") == "search_document: ")
    }
}
