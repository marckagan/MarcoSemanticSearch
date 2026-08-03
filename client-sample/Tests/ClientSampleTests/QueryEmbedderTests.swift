// QueryEmbedderTests.swift
//
// The "search_query: " prefix is the counterpart to the server's
// "search_document: " prefix (see server-sample's EmbedderTests.swift) --
// get either one wrong and relevance degrades silently, no crash. This
// tests the pure prefixing logic directly, independent of the (currently
// fatalError-stubbed) real Core ML embedding call.

import Testing
@testable import ClientSample

struct QueryEmbedderTests {
    @Test("prefixedForQuery applies the search_query: prefix")
    func appliesPrefix() {
        #expect(QueryEmbedder.prefixedForQuery("sourdough starter dying") == "search_query: sourdough starter dying")
    }

    @Test("prefixedForQuery uses the declared queryPrefix constant")
    func usesDeclaredConstant() {
        let text = "what was that episode about?"
        #expect(QueryEmbedder.prefixedForQuery(text) == QueryEmbedder.queryPrefix + text)
    }

    @Test("the query prefix is not accidentally the document prefix")
    func queryPrefixDiffersFromDocumentPrefix() {
        // Using the wrong one of these two is the specific failure mode
        // flagged throughout the docs -- pin down that they're actually
        // different strings, not the same constant reused by mistake.
        #expect(QueryEmbedder.queryPrefix != "search_document: ")
        #expect(QueryEmbedder.queryPrefix == "search_query: ")
    }
}
