// ExplanationTagParserTests.swift — DecodeTests
// Comprehensive unit tests for ExplanationTagParser.

import Testing
import Foundation
@testable import Decode

@Suite
struct ExplanationTagParserParseTests {

    // MARK: - Empty / Plain Input

    @Test func emptyInputReturnsEmpty() {
        let result = ExplanationTagParser.parse("")
        #expect(result.isEmpty)
    }

    @Test func plainTextReturnsOnePlainSegment() {
        let result = ExplanationTagParser.parse("Hello world")
        #expect(result == [.plain("Hello world")])
    }

    // MARK: - Single Tags

    @Test func singleHlTag() {
        let result = ExplanationTagParser.parse("before <hl>highlighted</hl> after")
        #expect(result == [
            .plain("before "),
            .tagged(.hl, "highlighted"),
            .plain(" after")
        ])
    }

    @Test func singleCriticalTag() {
        let result = ExplanationTagParser.parse("<critical>warning</critical>")
        #expect(result == [.tagged(.critical, "warning")])
    }

    @Test func singleTipTag() {
        let result = ExplanationTagParser.parse("<tip>advice</tip>")
        #expect(result == [.tagged(.tip, "advice")])
    }

    @Test func singleNoteTag() {
        let result = ExplanationTagParser.parse("<note>info</note>")
        #expect(result == [.tagged(.note, "info")])
    }

    @Test func singleAnalogyTag() {
        let result = ExplanationTagParser.parse("<analogy>like a pipe</analogy>")
        #expect(result == [.tagged(.analogy, "like a pipe")])
    }

    @Test func singleFlowTag() {
        let result = ExplanationTagParser.parse("<flow>step1 → step2</flow>")
        #expect(result == [.tagged(.flow, "step1 → step2")])
    }

    @Test func singleTldrTag() {
        let result = ExplanationTagParser.parse("<tldr>summary here</tldr>")
        #expect(result == [.tagged(.tldr, "summary here")])
    }

    // MARK: - Case-Insensitive Closing Tags

    @Test func caseInsensitiveClosingTag() {
        let result = ExplanationTagParser.parse("<hl>text</HL>")
        #expect(result == [.tagged(.hl, "text")])
    }

    @Test func mixedCaseClosingTag() {
        let result = ExplanationTagParser.parse("<hl>text</Hl>")
        #expect(result == [.tagged(.hl, "text")])
    }

    // MARK: - Empty Tags

    @Test func emptyTagSkipped() {
        let result = ExplanationTagParser.parse("before<hl></hl>after")
        #expect(result == [.plain("before"), .plain("after")])
    }

    // MARK: - Unclosed Tags

    @Test func unclosedTagTreatedAsPlainText() {
        let result = ExplanationTagParser.parse("before <hl>no close")
        #expect(result == [.plain("before <hl>no close")])
    }

    // MARK: - Nested Tags

    @Test func nestedTagsOutermostWins() {
        let result = ExplanationTagParser.parse("<hl>outer <tip>inner</tip> end</hl>")
        #expect(result == [.tagged(.hl, "outer <tip>inner</tip> end")])
    }

    // MARK: - Multiple Tags

    @Test func multipleConsecutiveTags() {
        let result = ExplanationTagParser.parse("<hl>a</hl><tip>b</tip>")
        #expect(result == [.tagged(.hl, "a"), .tagged(.tip, "b")])
    }

    @Test func multipleTagsWithPlainBetween() {
        let result = ExplanationTagParser.parse("<hl>first</hl> middle <note>second</note>")
        #expect(result == [
            .tagged(.hl, "first"),
            .plain(" middle "),
            .tagged(.note, "second")
        ])
    }

    // MARK: - Unrecognized Tags

    @Test func unknownTagTreatedAsPlainText() {
        let result = ExplanationTagParser.parse("<unknown>text</unknown>")
        #expect(result == [.plain("<unknown>text</unknown>")])
    }

    // MARK: - Angle Brackets Without Tags

    @Test func angleBracketWithoutTagName() {
        let result = ExplanationTagParser.parse("a < b > c")
        #expect(result == [.plain("a < b > c")])
    }

    // MARK: - Tags With Attributes

    @Test func tagWithAttributesStillMatches() {
        let result = ExplanationTagParser.parse("<hl class=\"x\">text</hl>")
        #expect(result == [.tagged(.hl, "text")])
    }
}

// MARK: - Grouper Tests

@Suite
struct ExplanationTagParserGroupTests {

    @Test func emptySegmentsProduceNoBlocks() {
        let result = ExplanationTagParser.group([])
        #expect(result.isEmpty)
    }

    @Test func plainSegmentBecomesInlineRun() {
        let result = ExplanationTagParser.group([.plain("hello")])
        #expect(result.count == 1)
        if case .inlineRun(_, let segments) = result[0] {
            #expect(segments == [.plain("hello")])
        } else {
            Issue.record("Expected inlineRun")
        }
    }

    @Test func inlineTagsGroupedIntoSingleRun() {
        let segments: [TaggedSegment] = [
            .plain("before "),
            .tagged(.hl, "highlight"),
            .plain(" after")
        ]
        let result = ExplanationTagParser.group(segments)
        #expect(result.count == 1)
        if case .inlineRun(_, let segs) = result[0] {
            #expect(segs.count == 3)
        } else {
            Issue.record("Expected inlineRun")
        }
    }

    @Test func tldrBecomesStandaloneBlock() {
        let segments: [TaggedSegment] = [
            .plain("text"),
            .tagged(.tldr, "summary"),
            .plain("more text")
        ]
        let result = ExplanationTagParser.group(segments)
        #expect(result.count == 3)
        if case .tldr(_, let content) = result[1] {
            #expect(content == "summary")
        } else {
            Issue.record("Expected tldr block")
        }
    }

    @Test func flowBecomesStandaloneBlock() {
        let segments: [TaggedSegment] = [
            .tagged(.flow, "A → B → C")
        ]
        let result = ExplanationTagParser.group(segments)
        #expect(result.count == 1)
        if case .flow(_, let content) = result[0] {
            #expect(content == "A → B → C")
        } else {
            Issue.record("Expected flow block")
        }
    }

    @Test func blockTagFlushesInlineBuffer() {
        let segments: [TaggedSegment] = [
            .plain("before"),
            .tagged(.tldr, "summary"),
        ]
        let result = ExplanationTagParser.group(segments)
        #expect(result.count == 2)
        if case .inlineRun(_, _) = result[0] {} else {
            Issue.record("Expected inlineRun first")
        }
        if case .tldr(_, _) = result[1] {} else {
            Issue.record("Expected tldr second")
        }
    }

    @Test func sequentialIdsAssigned() {
        let segments: [TaggedSegment] = [
            .plain("a"),
            .tagged(.tldr, "b"),
            .plain("c")
        ]
        let result = ExplanationTagParser.group(segments)
        #expect(result.count == 3)
        #expect(result[0].id == 0)
        #expect(result[1].id == 1)
        #expect(result[2].id == 2)
    }
}

// MARK: - Sanitize Tests

@Suite
struct ExplanationTagParserSanitizeTests {

    @Test func emptyInputReturnedUnchanged() {
        #expect(ExplanationTagParser.sanitize("") == "")
    }

    @Test func markdownHeadingsConvertedToBold() {
        let input = "## Overview\nSome text"
        let result = ExplanationTagParser.sanitize(input)
        #expect(result.contains("**Overview**"))
        #expect(!result.contains("##"))
    }

    @Test func multiLevelHeadingsConverted() {
        let input = "# Title\n## Section\n### Subsection"
        let result = ExplanationTagParser.sanitize(input)
        #expect(result.contains("**Title**"))
        #expect(result.contains("**Section**"))
        #expect(result.contains("**Subsection**"))
    }

    @Test func unknownTagPairsUnwrapped() {
        let input = "<trace>fib(4) → 3</trace>"
        let result = ExplanationTagParser.sanitize(input)
        #expect(result.contains("fib(4) → 3"))
        #expect(!result.contains("<trace>"))
    }

    @Test func knownTagsPreservedDuringSanitize() {
        let input = "<hl>important</hl>"
        let result = ExplanationTagParser.sanitize(input)
        #expect(result.contains("<hl>important</hl>"))
    }

    @Test func orphanUnknownTagsStripped() {
        let input = "text <orphan> more text"
        let result = ExplanationTagParser.sanitize(input)
        #expect(!result.contains("<orphan>"))
        #expect(result.contains("text"))
        #expect(result.contains("more text"))
    }

    @Test func singleLetterTagsNotStripped() {
        // Single-letter tags like <T> should be preserved (generics).
        let input = "Array<T> is generic"
        let result = ExplanationTagParser.sanitize(input)
        #expect(result.contains("<T>"))
    }

    @Test func excessiveBlankLinesCollapsed() {
        let input = "line1\n\n\n\n\nline2"
        let result = ExplanationTagParser.sanitize(input)
        #expect(result == "line1\n\nline2")
    }

    @Test func twoBlankLinesPreserved() {
        let input = "line1\n\nline2"
        let result = ExplanationTagParser.sanitize(input)
        #expect(result == "line1\n\nline2")
    }
}

// MARK: - Full Pipeline (blocks) Tests

@Suite
struct ExplanationTagParserBlocksTests {

    @Test func emptyInputReturnsNoBlocks() {
        let result = ExplanationTagParser.blocks(from: "")
        #expect(result.isEmpty)
    }

    @Test func plainTextProducesInlineRun() {
        let result = ExplanationTagParser.blocks(from: "Hello world")
        #expect(result.count == 1)
        if case .inlineRun(_, _) = result[0] {} else {
            Issue.record("Expected inlineRun")
        }
    }

    @Test func fencedCodeBlockDetected() {
        let input = "text\n```swift\nlet x = 1\n```\nmore"
        let result = ExplanationTagParser.blocks(from: input)
        let codeBlocks = result.filter {
            if case .codeBlock(_, _, _) = $0 { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        if case .codeBlock(_, let lang, let code) = codeBlocks[0] {
            #expect(lang == "swift")
            #expect(code == "let x = 1")
        }
    }

    @Test func codeBlockLanguageOptional() {
        let input = "```\nplain code\n```"
        let result = ExplanationTagParser.blocks(from: input)
        let codeBlocks = result.filter {
            if case .codeBlock(_, _, _) = $0 { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        if case .codeBlock(_, let lang, _) = codeBlocks[0] {
            #expect(lang == nil)
        }
    }

    @Test func markdownTableDetected() {
        let input = "| A | B | C |\n| --- | --- | --- |\n| 1 | 2 | 3 |"
        let result = ExplanationTagParser.blocks(from: input)
        let tables = result.filter {
            if case .table(_, _, _) = $0 { return true }
            return false
        }
        #expect(tables.count == 1)
        if case .table(_, let headers, let rows) = tables[0] {
            #expect(headers == ["A", "B", "C"])
            #expect(rows.count == 1)
            #expect(rows[0] == ["1", "2", "3"])
        }
    }

    @Test func tagsInsideCodeBlockNotParsed() {
        let input = "```\n<hl>not a tag</hl>\n```"
        let result = ExplanationTagParser.blocks(from: input)
        // Should be a code block, not a tagged segment.
        let codeBlocks = result.filter {
            if case .codeBlock(_, _, _) = $0 { return true }
            return false
        }
        #expect(codeBlocks.count == 1)
        if case .codeBlock(_, _, let code) = codeBlocks[0] {
            #expect(code.contains("<hl>"))
        }
    }

    @Test func headingsSanitizedBeforeParsing() {
        let input = "## Title\n<hl>text</hl>"
        let result = ExplanationTagParser.blocks(from: input)
        // Title should be converted to bold, not left as heading.
        let hasHeading = result.contains { block in
            if case .inlineRun(_, let segs) = block {
                return segs.contains { seg in
                    if case .plain(let text) = seg {
                        return text.contains("##")
                    }
                    return false
                }
            }
            return false
        }
        #expect(!hasHeading)
    }

    @Test func sequentialBlockIdsStartAtZero() {
        let input = "text\n<tldr>summary</tldr>\nmore"
        let result = ExplanationTagParser.blocks(from: input)
        for (i, block) in result.enumerated() {
            #expect(block.id == i)
        }
    }

    @Test func mixedInlineAndBlockTags() {
        let input = "<hl>important</hl>\n<tldr>summary</tldr>\n<tip>helpful</tip>"
        let result = ExplanationTagParser.blocks(from: input)
        // Should have at least an inline run, a tldr block, and another inline run.
        let hasTldr = result.contains { block in
            if case .tldr(_, _) = block { return true }
            return false
        }
        #expect(hasTldr)
    }
}

// MARK: - ContentBlock Tests

@Suite
struct ContentBlockTests {

    @Test func withIDReturnsNewID() {
        let block = ContentBlock.tldr(id: 5, content: "test")
        let updated = block.withID(42)
        #expect(updated.id == 42)
        if case .tldr(_, let content) = updated {
            #expect(content == "test")
        }
    }

    @Test func withIDPreservesFlowContent() {
        let block = ContentBlock.flow(id: 0, content: "A → B")
        let updated = block.withID(7)
        if case .flow(_, let content) = updated {
            #expect(content == "A → B")
        } else {
            Issue.record("Expected flow")
        }
    }

    @Test func withIDPreservesCodeBlockFields() {
        let block = ContentBlock.codeBlock(id: 0, language: "swift", code: "let x = 1")
        let updated = block.withID(3)
        if case .codeBlock(_, let lang, let code) = updated {
            #expect(lang == "swift")
            #expect(code == "let x = 1")
        } else {
            Issue.record("Expected codeBlock")
        }
    }

    @Test func withIDPreservesTableFields() {
        let block = ContentBlock.table(id: 0, headers: ["A"], rows: [["1"]])
        let updated = block.withID(9)
        if case .table(_, let headers, let rows) = updated {
            #expect(headers == ["A"])
            #expect(rows == [["1"]])
        } else {
            Issue.record("Expected table")
        }
    }
}

// MARK: - ExplanationTag Tests

@Suite
struct ExplanationTagTests {

    @Test func blockTagsAreFlowAndTldr() {
        #expect(ExplanationTag.flow.isBlock)
        #expect(ExplanationTag.tldr.isBlock)
    }

    @Test func inlineTagsAreNotBlock() {
        #expect(!ExplanationTag.hl.isBlock)
        #expect(!ExplanationTag.critical.isBlock)
        #expect(!ExplanationTag.tip.isBlock)
        #expect(!ExplanationTag.note.isBlock)
        #expect(!ExplanationTag.analogy.isBlock)
    }

    @Test func allCasesHasSevenTags() {
        #expect(ExplanationTag.allCases.count == 7)
    }
}
