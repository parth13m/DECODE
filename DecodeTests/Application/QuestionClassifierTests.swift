// QuestionClassifierTests.swift — DecodeTests
// E3-01: Question-Aware Scope Selection — Comprehensive tests for QuestionClassifier.
//
// Validates that the classifier correctly maps (purpose, questionHint)
// to (RetrievalIntent, RetrievalScope) pairs using keyword-based rules.

import Testing
import Foundation
@testable import Decode
import RetrievalRuntime

// MARK: - Purpose Default Tests

@Suite("QuestionClassifier: Purpose Defaults")
struct QuestionClassifierPurposeDefaultTests {

    @Test("explain purpose defaults to .explain intent with .module scope")
    func testExplainDefault() {
        let result = QuestionClassifier.classify(purpose: "explain")
        #expect(result.intent == .explain)
        #expect(result.scope == .module)
        #expect(result.matchedRule == .purposeDefault)
    }

    @Test("improve purpose defaults to .explain intent with .local scope")
    func testImproveDefault() {
        let result = QuestionClassifier.classify(purpose: "improve")
        #expect(result.intent == .explain)
        #expect(result.scope == .local)
        #expect(result.matchedRule == .purposeDefault)
    }

    @Test("followup purpose defaults to .explain intent with .module scope")
    func testFollowupDefault() {
        let result = QuestionClassifier.classify(purpose: "followup")
        #expect(result.intent == .explain)
        #expect(result.scope == .module)
        #expect(result.matchedRule == .purposeDefault)
    }

    @Test("unknown purpose defaults to .explain intent with .module scope")
    func testUnknownPurpose() {
        let result = QuestionClassifier.classify(purpose: "analyze")
        #expect(result.intent == .explain)
        #expect(result.scope == .module)
        #expect(result.matchedRule == .purposeDefault)
    }

    @Test("nil question hint uses purpose defaults")
    func testNilQuestionHint() {
        let result = QuestionClassifier.classify(purpose: "explain", questionHint: nil)
        #expect(result.matchedRule == .purposeDefault)
    }

    @Test("empty question hint uses purpose defaults")
    func testEmptyQuestionHint() {
        let result = QuestionClassifier.classify(purpose: "explain", questionHint: "")
        #expect(result.matchedRule == .purposeDefault)
    }
}

// MARK: - Impact Keyword Tests

@Suite("QuestionClassifier: Impact Keywords")
struct QuestionClassifierImpactTests {

    @Test("'who calls' triggers impact intent")
    func testWhoCallsKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "who calls this method?"
        )
        #expect(result.intent == .impact)
        #expect(result.scope == .module)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("'what uses' triggers impact intent")
    func testWhatUsesKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what uses this function?"
        )
        #expect(result.intent == .impact)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("'callers' triggers impact intent")
    func testCallersKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "show me all callers of validate"
        )
        #expect(result.intent == .impact)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("'what would break' triggers impact intent")
    func testWhatWouldBreakKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what would break if I changed this?"
        )
        #expect(result.intent == .impact)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("'downstream' triggers impact intent")
    func testDownstreamKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what is the downstream impact?"
        )
        #expect(result.intent == .impact)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("'who implements' triggers impact intent")
    func testWhoImplementsKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "who implements this protocol?"
        )
        #expect(result.intent == .impact)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("impact keywords are case insensitive")
    func testCaseInsensitive() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "WHO CALLS this?"
        )
        #expect(result.intent == .impact)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("impact ensures at least module scope")
    func testImpactEnsuresModuleScope() {
        // Even if purpose is "improve" (which defaults to .local),
        // impact keywords should upgrade to .module
        let result = QuestionClassifier.classify(
            purpose: "improve",
            questionHint: "who calls this method?"
        )
        #expect(result.intent == .impact)
        #expect(result.scope == .module)
    }
}

// MARK: - Dependency Keyword Tests

@Suite("QuestionClassifier: Dependency Keywords")
struct QuestionClassifierDependencyTests {

    @Test("'what does this depend on' triggers dependency intent")
    func testDependsOnKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what does this depend on?"
        )
        #expect(result.intent == .dependencies)
        #expect(result.scope == .module)
        #expect(result.matchedRule == .dependencyKeywords)
    }

    @Test("'what does this call' triggers dependency intent")
    func testWhatDoesThisCallKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what does this call internally?"
        )
        #expect(result.intent == .dependencies)
        #expect(result.matchedRule == .dependencyKeywords)
    }

    @Test("'imports' triggers dependency intent")
    func testImportsKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what does this import?"
        )
        #expect(result.intent == .dependencies)
        #expect(result.matchedRule == .dependencyKeywords)
    }

    @Test("'upstream' triggers dependency intent")
    func testUpstreamKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what are the upstream dependencies?"
        )
        #expect(result.intent == .dependencies)
        #expect(result.matchedRule == .dependencyKeywords)
    }

    @Test("'inherits from' triggers dependency intent")
    func testInheritsFromKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what does this inherit from?"
        )
        #expect(result.intent == .dependencies)
        #expect(result.matchedRule == .dependencyKeywords)
    }
}

// MARK: - Overview Keyword Tests

@Suite("QuestionClassifier: Overview Keywords")
struct QuestionClassifierOverviewTests {

    @Test("'architecture' triggers overview intent")
    func testArchitectureKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what is the architecture here?"
        )
        #expect(result.intent == .overview)
        #expect(result.scope == .module)
        #expect(result.matchedRule == .overviewKeywords)
    }

    @Test("'overview' triggers overview intent")
    func testOverviewKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "give me an overview of this service"
        )
        #expect(result.intent == .overview)
        #expect(result.matchedRule == .overviewKeywords)
    }

    @Test("'how does this fit' triggers overview intent")
    func testHowDoesThisFitKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "how does this fit in the system?"
        )
        #expect(result.intent == .overview)
        #expect(result.matchedRule == .overviewKeywords)
    }

    @Test("'big picture' triggers overview intent")
    func testBigPictureKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what's the big picture here?"
        )
        #expect(result.intent == .overview)
        #expect(result.matchedRule == .overviewKeywords)
    }

    @Test("'design pattern' triggers overview intent")
    func testDesignPatternKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what design pattern is this?"
        )
        #expect(result.intent == .overview)
        #expect(result.matchedRule == .overviewKeywords)
    }

    @Test("'high-level' triggers overview intent")
    func testHighLevelKeyword() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "can you give a high-level explanation?"
        )
        #expect(result.intent == .overview)
        #expect(result.matchedRule == .overviewKeywords)
    }
}

// MARK: - Narrow Keyword Tests

@Suite("QuestionClassifier: Narrow Keywords")
struct QuestionClassifierNarrowTests {

    @Test("'what does this do' triggers narrow scope")
    func testWhatDoesThisDo() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what does this do?"
        )
        #expect(result.intent == .explain)
        #expect(result.scope == .local)
        #expect(result.matchedRule == .narrowKeywords)
    }

    @Test("'what does this line' triggers narrow scope")
    func testWhatDoesThisLine() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what does this line mean?"
        )
        #expect(result.intent == .explain)
        #expect(result.scope == .local)
        #expect(result.matchedRule == .narrowKeywords)
    }

    @Test("'just this' triggers narrow scope")
    func testJustThis() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "explain just this function"
        )
        #expect(result.intent == .explain)
        #expect(result.scope == .local)
        #expect(result.matchedRule == .narrowKeywords)
    }

    @Test("'what type' triggers narrow scope")
    func testWhatType() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what type does this return?"
        )
        #expect(result.intent == .explain)
        #expect(result.scope == .local)
        #expect(result.matchedRule == .narrowKeywords)
    }
}

// MARK: - Priority Tests

@Suite("QuestionClassifier: Priority Order")
struct QuestionClassifierPriorityTests {

    @Test("impact takes priority over dependency when both match")
    func testImpactOverDependency() {
        // "what depends on" matches impact, "depends on" could match dependency
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what depends on this? show callers and dependents"
        )
        #expect(result.intent == .impact)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("impact takes priority over overview")
    func testImpactOverOverview() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "who calls this in the architecture?"
        )
        #expect(result.intent == .impact)
        #expect(result.matchedRule == .impactKeywords)
    }

    @Test("dependency takes priority over overview")
    func testDependencyOverOverview() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what does this depend on in the architecture?"
        )
        #expect(result.intent == .dependencies)
        #expect(result.matchedRule == .dependencyKeywords)
    }

    @Test("overview takes priority over narrow")
    func testOverviewOverNarrow() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "what does this do in terms of the big picture?"
        )
        // "big picture" matches overview, "what does this do" matches narrow
        // Overview should win because it's checked first
        #expect(result.intent == .overview)
        #expect(result.matchedRule == .overviewKeywords)
    }

    @Test("no keyword match falls through to fallback")
    func testFallback() {
        let result = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "can you explain the error handling?"
        )
        #expect(result.intent == .explain)
        #expect(result.scope == .module)
        #expect(result.matchedRule == .fallback)
    }
}

// MARK: - Determinism Tests

@Suite("QuestionClassifier: Determinism")
struct QuestionClassifierDeterminismTests {

    @Test("same inputs always produce same output")
    func testDeterministic() {
        let result1 = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "who calls this?"
        )
        let result2 = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "who calls this?"
        )
        #expect(result1 == result2)
    }

    @Test("classification is purely based on inputs, no state")
    func testStateless() {
        // Classify impact first, then explain — ensure no state leakage
        _ = QuestionClassifier.classify(
            purpose: "followup",
            questionHint: "who calls this?"
        )
        let result = QuestionClassifier.classify(purpose: "explain")
        #expect(result.intent == .explain)
        #expect(result.scope == .module)
        #expect(result.matchedRule == .purposeDefault)
    }
}

// MARK: - Keyword Coverage Tests

@Suite("QuestionClassifier: Keyword Coverage")
struct QuestionClassifierKeywordCoverageTests {

    @Test("all impact keywords produce impact classification")
    func testAllImpactKeywords() {
        for keyword in QuestionClassifier.impactKeywords {
            let result = QuestionClassifier.classify(
                purpose: "followup",
                questionHint: "question with \(keyword) in it"
            )
            #expect(
                result.intent == .impact,
                "Expected .impact for keyword '\(keyword)' but got \(result.intent)"
            )
        }
    }

    @Test("all dependency keywords produce dependency classification")
    func testAllDependencyKeywords() {
        for keyword in QuestionClassifier.dependencyKeywords {
            // Skip keywords that also match impact patterns
            let impactFirst = QuestionClassifier.impactKeywords.contains {
                "question with \(keyword) in it".lowercased().contains($0)
            }
            if impactFirst { continue }

            let result = QuestionClassifier.classify(
                purpose: "followup",
                questionHint: "question with \(keyword) in it"
            )
            #expect(
                result.intent == .dependencies,
                "Expected .dependencies for keyword '\(keyword)' but got \(result.intent)"
            )
        }
    }

    @Test("all overview keywords produce overview classification")
    func testAllOverviewKeywords() {
        for keyword in QuestionClassifier.overviewKeywords {
            let result = QuestionClassifier.classify(
                purpose: "followup",
                questionHint: "question with \(keyword) in it"
            )
            #expect(
                result.intent == .overview,
                "Expected .overview for keyword '\(keyword)' but got \(result.intent)"
            )
        }
    }

    @Test("all narrow keywords produce narrow classification")
    func testAllNarrowKeywords() {
        for keyword in QuestionClassifier.narrowKeywords {
            // Skip keywords that also match higher-priority patterns
            let higherPriority = QuestionClassifier.impactKeywords.contains {
                "question with \(keyword) in it".lowercased().contains($0)
            } || QuestionClassifier.dependencyKeywords.contains {
                "question with \(keyword) in it".lowercased().contains($0)
            } || QuestionClassifier.overviewKeywords.contains {
                "question with \(keyword) in it".lowercased().contains($0)
            }
            if higherPriority { continue }

            let result = QuestionClassifier.classify(
                purpose: "followup",
                questionHint: "question with \(keyword) in it"
            )
            #expect(
                result.matchedRule == .narrowKeywords,
                "Expected .narrowKeywords for keyword '\(keyword)' but got \(result.matchedRule)"
            )
        }
    }
}

// MARK: - Benchmark Integration Tests

@Suite("QuestionClassifier: Benchmark Corpus Integration")
struct QuestionClassifierBenchmarkTests {

    @Test("corpus question-aware cases have questionHint set")
    func testQuestionAwareCasesHaveHints() {
        let qaCases = BenchmarkCorpus.allCases.filter { $0.id.hasPrefix("qa-") }
        #expect(qaCases.count == 4)
        for qaCase in qaCases {
            #expect(
                qaCase.questionHint != nil,
                "Question-aware case '\(qaCase.id)' should have questionHint"
            )
        }
    }

    @Test("qa-01 impact case classifies to impact intent")
    func testImpactCaseClassification() {
        let impactCase = BenchmarkCorpus.findCase(id: "qa-01-impact-callers")!
        let classification = QuestionClassifier.classify(
            purpose: impactCase.purpose,
            questionHint: impactCase.questionHint
        )
        #expect(classification.intent == .impact)
        #expect(classification.matchedRule == .impactKeywords)
    }

    @Test("qa-02 dependency case classifies to dependencies intent")
    func testDependencyCaseClassification() {
        let depCase = BenchmarkCorpus.findCase(id: "qa-02-dependency-chain")!
        let classification = QuestionClassifier.classify(
            purpose: depCase.purpose,
            questionHint: depCase.questionHint
        )
        #expect(classification.intent == .dependencies)
        #expect(classification.matchedRule == .dependencyKeywords)
    }

    @Test("qa-03 overview case classifies to overview intent")
    func testOverviewCaseClassification() {
        let overviewCase = BenchmarkCorpus.findCase(id: "qa-03-overview-architecture")!
        let classification = QuestionClassifier.classify(
            purpose: overviewCase.purpose,
            questionHint: overviewCase.questionHint
        )
        #expect(classification.intent == .overview)
        #expect(classification.matchedRule == .overviewKeywords)
    }

    @Test("qa-04 narrow case classifies to explain intent with local scope")
    func testNarrowCaseClassification() {
        let narrowCase = BenchmarkCorpus.findCase(id: "qa-04-narrow-simple")!
        let classification = QuestionClassifier.classify(
            purpose: narrowCase.purpose,
            questionHint: narrowCase.questionHint
        )
        #expect(classification.intent == .explain)
        #expect(classification.scope == .local)
        #expect(classification.matchedRule == .narrowKeywords)
    }

    @Test("non-question-aware cases have nil questionHint")
    func testExistingCasesHaveNoHint() {
        let nonQaCases = BenchmarkCorpus.allCases.filter { !$0.id.hasPrefix("qa-") }
        #expect(nonQaCases.count > 0)
        for benchCase in nonQaCases {
            #expect(
                benchCase.questionHint == nil,
                "Non-QA case '\(benchCase.id)' should have nil questionHint"
            )
        }
    }

    @Test("existing cases classify to purpose defaults (backward compat)")
    func testExistingCasesClassifyToDefaults() {
        let explainCases = BenchmarkCorpus.allCases.filter {
            $0.purpose == "explain" && $0.questionHint == nil
        }
        #expect(explainCases.count > 0)
        for benchCase in explainCases {
            let classification = QuestionClassifier.classify(
                purpose: benchCase.purpose,
                questionHint: benchCase.questionHint
            )
            #expect(classification.intent == .explain)
            #expect(classification.scope == .module)
            #expect(classification.matchedRule == .purposeDefault)
        }
    }

    @Test("corpus now has qa- prefixed cases")
    func testCorpusPrefixes() {
        let allPrefixes = Set(BenchmarkCorpus.allCases.map {
            String($0.id.prefix(while: { $0 != "-" })) + "-"
        })
        #expect(allPrefixes.contains("qa-"))
    }

    @Test("corpus case count increased to 30")
    func testCorpusCaseCount() {
        #expect(BenchmarkCorpus.allCases.count == 30)
    }
}
