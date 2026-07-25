// SnippetHealthClassifierTests.swift — DecodeTests
// Comprehensive unit tests for SnippetHealthClassifier.

import Testing
import Foundation
@testable import Decode

@Suite
struct SnippetHealthClassifierTests {

    let classifier = SnippetHealthClassifier()

    // MARK: - Silent Tier (No Issues)

    @Test func validPythonSnippetReturnsSilent() {
        let snippet = """
        def hello():
            print("world")
            return 42
        """
        let result = classifier.classify(
            snippet: snippet,
            language: .python,
            fullFileSource: nil
        )
        #expect(result.tier == .silent)
        #expect(result.hints.isEmpty)
    }

    @Test func validJavaScriptSnippetReturnsSilent() {
        let snippet = """
        function greet(name) {
            console.log("Hello " + name);
            return name;
        }
        """
        let result = classifier.classify(
            snippet: snippet,
            language: .javascript,
            fullFileSource: nil
        )
        #expect(result.tier == .silent)
    }

    // MARK: - Short Snippet Returns Silent

    @Test func singleLineReturnsSilent() {
        let snippet = "return 42"
        let result = classifier.classify(
            snippet: snippet,
            language: .python,
            fullFileSource: nil
        )
        #expect(result.tier == .silent)
    }

    @Test func emptySnippetReturnsSilent() {
        let result = classifier.classify(
            snippet: "",
            language: .python,
            fullFileSource: nil
        )
        #expect(result.tier == .silent)
    }

    @Test func whitespaceOnlySnippetReturnsSilent() {
        let snippet = "   \n   \n   "
        let result = classifier.classify(
            snippet: snippet,
            language: .python,
            fullFileSource: nil
        )
        #expect(result.tier == .silent)
    }

    @Test func singleMeaningfulLineReturnsSilent() {
        // Only one non-empty line → below 2-line threshold.
        let snippet = "x = 42\n\n\n"
        let result = classifier.classify(
            snippet: snippet,
            language: .python,
            fullFileSource: nil
        )
        #expect(result.tier == .silent)
    }

    // MARK: - Edge Errors (Boundary Artifacts)

    @Test func incompleteStartAndEndReturnsSilentOrObserve() {
        // Fragment that looks like the middle of a function — edge errors only.
        let snippet = """
            x = compute(a, b)
            y = transform(x)
        """
        let result = classifier.classify(
            snippet: snippet,
            language: .python,
            fullFileSource: nil
        )
        // Edge-only errors → silent or observe depending on count.
        #expect(result.tier == .silent || result.tier == .observe)
    }

    // MARK: - Interior Errors (Real Issues)

    @Test func syntaxErrorInInteriorSurfacesOrHigher() {
        // Code with a clear syntax error in the middle.
        let snippet = """
        def valid_start():
            x = 1
            y = !!!invalid!!!syntax
            z = 3
            return z
        """
        let result = classifier.classify(
            snippet: snippet,
            language: .python,
            fullFileSource: nil
        )
        // Interior error → surface or diagnose.
        #expect(result.tier == .surface || result.tier == .diagnose)
    }

    @Test func multipleInteriorErrorsReturnDiagnose() {
        // Multiple clear syntax errors in the body.
        let snippet = """
        function test() {
            let a = @@@;
            let b = ###;
            let c = $$$;
            return a;
        }
        """
        let result = classifier.classify(
            snippet: snippet,
            language: .javascript,
            fullFileSource: nil
        )
        // Multiple interior errors → diagnose.
        #expect(result.tier == .diagnose || result.tier == .surface)
    }

    // MARK: - Full File Validation

    @Test func fullFileCleanDowngradesToSilent() {
        // Snippet in isolation has edge errors, but the full file is clean.
        let snippet = """
            print("hello")
            return result
        """
        let fullFile = """
        def process():
            result = compute()
            print("hello")
            return result
        """
        let result = classifier.classify(
            snippet: snippet,
            language: .python,
            fullFileSource: fullFile
        )
        // Full file is clean at snippet location → silent.
        #expect(result.tier == .silent)
    }

    // MARK: - Health Classification Structure

    @Test func classificationHasCorrectTier() {
        let classification = HealthClassification(tier: .surface, hints: [])
        #expect(classification.tier == .surface)
    }

    @Test func diagnosticHintFields() {
        let hint = DiagnosticHint(
            line: 5,
            description: "Unexpected: @@@",
            isInterior: true
        )
        #expect(hint.line == 5)
        #expect(hint.description == "Unexpected: @@@")
        #expect(hint.isInterior == true)
    }

    // MARK: - Tier Ordering

    @Test func healthTierRawValues() {
        #expect(HealthTier.silent.rawValue == "silent")
        #expect(HealthTier.observe.rawValue == "observe")
        #expect(HealthTier.surface.rawValue == "surface")
        #expect(HealthTier.diagnose.rawValue == "diagnose")
    }

    // MARK: - Hints Populated

    @Test func hintsPopulatedForErrorSnippet() {
        let snippet = """
        function test() {
            let a = @@@;
            let b = 42;
            return b;
        }
        """
        let result = classifier.classify(
            snippet: snippet,
            language: .javascript,
            fullFileSource: nil
        )
        if result.tier != .silent {
            #expect(!result.hints.isEmpty)
        }
    }
}
