// BenchmarkSuiteTests.swift — DecodeTests
// E1-01: Tests for the Benchmark Suite — pipeline-level evaluation.
//
// Tests the benchmark types, runner, comparator, and report formatter.
// Uses the deterministic ExplainReasoningEngine (no AI provider) to validate
// metric extraction, expectation checking, and comparison logic.

import Testing
import Foundation
@testable import Decode
import ConsumerRuntime
import ContextAssembly
import RetrievalRuntime
import DIRCore

// MARK: - Test Helpers

private let testHash = ContentHash(bytes: Array(repeating: 0, count: 32))

private func makeUnit(
    id: UInt64,
    entityName: String,
    predicateName: String,
    predicateDomain: String = "structure",
    value: TypedValue,
    tier: Tier = .t0
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .entity(EntityReference(qualifiedName: entityName)),
        predicate: PredicateIdentifier(name: predicateName, domain: predicateDomain),
        value: value,
        tier: tier,
        provenance: ProvenanceRecord(
            producer: "test-producer",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 0)
        ),
        confidence: tier == .t0 ? .deterministic : .high,
        grounding: .direct(SourcePosition(
            filePath: "test.swift",
            startLine: 1,
            endLine: 10,
            fileVersion: testHash
        )),
        version: VersionStamp(singleSource: testHash)
    )
}

private func makeRelUnit(
    id: UInt64,
    source: String,
    target: String,
    predicate: String
) -> AtomicUnit {
    AtomicUnit(
        id: UnitIdentifier(rawValue: id),
        subject: .pair(EntityPair(
            source: EntityReference(qualifiedName: source),
            target: EntityReference(qualifiedName: target)
        )),
        predicate: PredicateIdentifier(name: predicate, domain: "dependency"),
        value: .boolean(true),
        tier: .t0,
        provenance: ProvenanceRecord(
            producer: "test-producer",
            method: .extraction,
            timestamp: Date(timeIntervalSince1970: 0)
        ),
        confidence: .deterministic,
        grounding: .direct(SourcePosition(
            filePath: "test.swift",
            startLine: 1,
            endLine: 5,
            fileVersion: testHash
        )),
        version: VersionStamp(singleSource: testHash)
    )
}

// MARK: - Benchmark Types Tests

@Suite("BenchmarkTypes")
struct BenchmarkTypesTests {

    @Test("BenchmarkCase construction")
    func testBenchmarkCaseConstruction() {
        let benchCase = BenchmarkCase(
            id: "test-case",
            name: "Test Case",
            description: "A test benchmark case",
            category: .entityDiscovery,
            sourceFiles: [
                BenchmarkSourceFile(fileName: "Test.swift", content: "class Test {}")
            ],
            queryEntity: "Test",
            purpose: "explain",
            expectations: BenchmarkExpectations(
                expectedEntities: ["Test"],
                expectedPredicates: ["kind"],
                requireSuccess: true
            )
        )

        #expect(benchCase.id == "test-case")
        #expect(benchCase.sourceFiles.count == 1)
        #expect(benchCase.expectations.expectedEntities == ["Test"])
    }

    @Test("BenchmarkMetrics is Codable")
    func testBenchmarkMetricsCodable() throws {
        let metrics = BenchmarkMetrics(
            retrievalLatency: 0.005,
            contextAssemblyLatency: 0.002,
            reasoningLatency: 0.010,
            totalLatency: 0.020,
            evidenceUnitCount: 10,
            contextUnitCount: 8,
            unusedEvidence: 2,
            compressionRatio: 0.8,
            evidenceByStage: ["direct": 6, "relational": 4],
            evidenceByTier: ["t0": 8, "t1": 2],
            entityRecall: 1.0,
            foundEntities: ["Service", "Repository"],
            missingEntities: [],
            relationshipRecall: 0.5,
            foundRelationships: ["Service -[calls]-> Repository"],
            missingRelationships: ["Service -[conformsTo]-> Protocol"],
            predicateRecall: 0.75,
            foundPredicates: ["kind", "signature", "hasMethod"],
            missingPredicates: ["conformsTo"],
            groundingCoverage: 0.6,
            totalClaims: 5,
            claimTypeDistribution: ["factual": 3, "derived": 2],
            completeness: "complete",
            degradationLevel: "full",
            budgetUtilization: 0.4,
            contentLength: 500,
            stratumDistribution: ["direct": 6, "relational": 2],
            engineIdentifier: "com.decode.explain",
            engineVersion: "1.0.0"
        )

        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(BenchmarkMetrics.self, from: data)

        #expect(decoded == metrics)
    }

    @Test("BenchmarkResult is Codable")
    func testBenchmarkResultCodable() throws {
        let result = BenchmarkResult(
            caseId: "test",
            caseName: "Test",
            category: "entityDiscovery",
            timestamp: Date(timeIntervalSince1970: 1000),
            success: true,
            metrics: nil,
            violations: [
                ExpectationViolation(
                    expectation: "entityRecall >= 1.0",
                    actual: "0.5",
                    description: "Missing entity"
                )
            ],
            error: nil,
            failureStage: nil
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(BenchmarkResult.self, from: data)

        #expect(decoded.caseId == "test")
        #expect(decoded.violations.count == 1)
    }

    @Test("BenchmarkReport round-trips through JSON")
    func testReportCodable() throws {
        let report = BenchmarkReport(
            runId: "test-run",
            timestamp: Date(timeIntervalSince1970: 2000),
            engineVersion: "1.0.0",
            results: [],
            summary: BenchmarkSummary(
                totalCases: 0, succeeded: 0, failed: 0,
                expectationsMet: 0, expectationsViolated: 0,
                averageEntityRecall: 0, averageRelationshipRecall: 0,
                averagePredicateRecall: 0, averageGroundingCoverage: 0,
                averageEvidenceCount: 0, averageContextUnitCount: 0,
                averageCompressionRatio: 0, averageRetrievalLatency: 0,
                averageAssemblyLatency: 0, averageReasoningLatency: 0,
                averageTotalLatency: 0, averageBudgetUtilization: 0,
                averageContentLength: 0,
                completenessDistribution: [:],
                totalMissingEntities: 0, totalMissingRelationships: 0,
                categoryScores: [:]
            ),
            comparison: nil
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: data)

        #expect(decoded.runId == "test-run")
    }

    @Test("BenchmarkCategory covers all cases")
    func testCategoryEnum() {
        let allCases = BenchmarkCategory.allCases
        #expect(allCases.count == 6)
        #expect(allCases.contains(.entityDiscovery))
        #expect(allCases.contains(.relationshipResolution))
        #expect(allCases.contains(.crossFileResolution))
        #expect(allCases.contains(.moduleContext))
        #expect(allCases.contains(.contextAssembly))
        #expect(allCases.contains(.edgeCase))
    }
}

// MARK: - Benchmark Comparator Tests

@Suite("BenchmarkComparator")
struct BenchmarkComparatorTests {

    private func makeMetrics(
        entityRecall: Double = 1.0,
        relationshipRecall: Double = 1.0,
        groundingCoverage: Double = 0.5,
        totalLatency: TimeInterval = 0.01
    ) -> BenchmarkMetrics {
        BenchmarkMetrics(
            retrievalLatency: totalLatency * 0.3,
            contextAssemblyLatency: totalLatency * 0.2,
            reasoningLatency: totalLatency * 0.5,
            totalLatency: totalLatency,
            evidenceUnitCount: 10,
            contextUnitCount: 8,
            unusedEvidence: 2,
            compressionRatio: 0.8,
            evidenceByStage: ["direct": 10],
            evidenceByTier: ["t0": 10],
            entityRecall: entityRecall,
            foundEntities: ["A"],
            missingEntities: entityRecall < 1.0 ? ["B"] : [],
            relationshipRecall: relationshipRecall,
            foundRelationships: [],
            missingRelationships: [],
            predicateRecall: 1.0,
            foundPredicates: ["kind"],
            missingPredicates: [],
            groundingCoverage: groundingCoverage,
            totalClaims: 3,
            claimTypeDistribution: ["factual": 3],
            completeness: "complete",
            degradationLevel: "full",
            budgetUtilization: 0.4,
            contentLength: 200,
            stratumDistribution: ["primary": 8],
            engineIdentifier: "com.decode.explain",
            engineVersion: "1.0.0"
        )
    }

    private func makeResult(caseId: String, metrics: BenchmarkMetrics) -> BenchmarkResult {
        BenchmarkResult(
            caseId: caseId, caseName: caseId, category: "entityDiscovery",
            timestamp: Date(), success: true, metrics: metrics,
            violations: [], error: nil, failureStage: nil
        )
    }

    private func makeReport(runId: String, results: [BenchmarkResult]) -> BenchmarkReport {
        BenchmarkReport(
            runId: runId, timestamp: Date(), engineVersion: "1.0.0",
            results: results,
            summary: BenchmarkSummary(
                totalCases: results.count, succeeded: results.count, failed: 0,
                expectationsMet: results.count, expectationsViolated: 0,
                averageEntityRecall: 1.0, averageRelationshipRecall: 1.0,
                averagePredicateRecall: 1.0, averageGroundingCoverage: 0.5,
                averageEvidenceCount: 10, averageContextUnitCount: 8,
                averageCompressionRatio: 0.8, averageRetrievalLatency: 0.003,
                averageAssemblyLatency: 0.002, averageReasoningLatency: 0.005,
                averageTotalLatency: 0.01, averageBudgetUtilization: 0.4,
                averageContentLength: 200,
                completenessDistribution: ["complete": results.count],
                totalMissingEntities: 0, totalMissingRelationships: 0,
                categoryScores: [:]
            ),
            comparison: nil
        )
    }

    @Test("Identical results show no regressions")
    func testIdentical() {
        let metrics = makeMetrics()
        let result = makeResult(caseId: "case-1", metrics: metrics)
        let baseline = makeReport(runId: "baseline", results: [result])

        let comparator = BenchmarkComparator()
        let comparison = comparator.compare(baseline: baseline, current: [result])

        #expect(comparison.passesBaseline)
        #expect(comparison.regressions.isEmpty)
    }

    @Test("Entity recall regression detected")
    func testEntityRecallRegression() {
        let baselineMetrics = makeMetrics(entityRecall: 1.0)
        let currentMetrics = makeMetrics(entityRecall: 0.5)

        let baselineResult = makeResult(caseId: "case-1", metrics: baselineMetrics)
        let currentResult = makeResult(caseId: "case-1", metrics: currentMetrics)
        let baseline = makeReport(runId: "baseline", results: [baselineResult])

        let comparator = BenchmarkComparator()
        let comparison = comparator.compare(baseline: baseline, current: [currentResult])

        #expect(!comparison.passesBaseline)
        #expect(comparison.regressions.contains { $0.metric == "entityRecall" })
    }

    @Test("Grounding improvement detected")
    func testGroundingImprovement() {
        let baselineMetrics = makeMetrics(groundingCoverage: 0.3)
        let currentMetrics = makeMetrics(groundingCoverage: 0.8)

        let baselineResult = makeResult(caseId: "case-1", metrics: baselineMetrics)
        let currentResult = makeResult(caseId: "case-1", metrics: currentMetrics)
        let baseline = makeReport(runId: "baseline", results: [baselineResult])

        let comparator = BenchmarkComparator()
        let comparison = comparator.compare(baseline: baseline, current: [currentResult])

        #expect(comparison.passesBaseline)
        #expect(comparison.improvements.contains { $0.metric == "groundingCoverage" })
    }

    @Test("Custom thresholds respected")
    func testCustomThresholds() {
        let baselineMetrics = makeMetrics(entityRecall: 1.0)
        let currentMetrics = makeMetrics(entityRecall: 0.95) // 5% drop

        let baselineResult = makeResult(caseId: "case-1", metrics: baselineMetrics)
        let currentResult = makeResult(caseId: "case-1", metrics: currentMetrics)
        let baseline = makeReport(runId: "baseline", results: [baselineResult])

        // Default threshold 0.1 → passes
        let lenient = BenchmarkComparator()
        #expect(lenient.compare(baseline: baseline, current: [currentResult]).passesBaseline)

        // Tight threshold 0.01 → fails
        let tight = BenchmarkComparator(thresholds: BenchmarkThresholds(
            entityRecallThreshold: 0.01,
            relationshipRecallThreshold: 0.01,
            predicateRecallThreshold: 0.01,
            groundingCoverageThreshold: 0.01,
            latencyThreshold: 0.01,
            compressionThreshold: 0.01,
            budgetUtilizationThreshold: 0.01
        ))
        #expect(!tight.compare(baseline: baseline, current: [currentResult]).passesBaseline)
    }

    @Test("New case without baseline passes")
    func testNewCase() {
        let baseline = makeReport(runId: "baseline", results: [])
        let current = makeResult(caseId: "new-case", metrics: makeMetrics())

        let comparator = BenchmarkComparator()
        let comparison = comparator.compare(baseline: baseline, current: [current])

        #expect(comparison.passesBaseline)
        #expect(comparison.caseComparisons.count == 1)
    }
}

// MARK: - Report Formatter Tests

@Suite("BenchmarkReportFormatter")
struct BenchmarkReportFormatterTests {

    @Test("Markdown report contains summary table")
    func testMarkdownSummary() {
        let report = BenchmarkReport(
            runId: "md-test",
            timestamp: Date(timeIntervalSince1970: 1000),
            engineVersion: "1.0.0",
            results: [
                BenchmarkResult(
                    caseId: "case-1", caseName: "Test Case", category: "entityDiscovery",
                    timestamp: Date(), success: true, metrics: nil,
                    violations: [], error: nil, failureStage: nil
                )
            ],
            summary: BenchmarkSummary(
                totalCases: 1, succeeded: 1, failed: 0,
                expectationsMet: 1, expectationsViolated: 0,
                averageEntityRecall: 1.0, averageRelationshipRecall: 0.5,
                averagePredicateRecall: 0.75, averageGroundingCoverage: 0.6,
                averageEvidenceCount: 5, averageContextUnitCount: 4,
                averageCompressionRatio: 0.8, averageRetrievalLatency: 0.005,
                averageAssemblyLatency: 0.002, averageReasoningLatency: 0.010,
                averageTotalLatency: 0.020, averageBudgetUtilization: 0.4,
                averageContentLength: 300,
                completenessDistribution: ["complete": 1],
                totalMissingEntities: 0, totalMissingRelationships: 1,
                categoryScores: [:]
            ),
            comparison: nil
        )

        let md = BenchmarkReportFormatter.formatMarkdown(report)

        #expect(md.contains("# Benchmark Report"))
        #expect(md.contains("md-test"))
        #expect(md.contains("Total cases"))
        #expect(md.contains("Avg entity recall"))
        #expect(md.contains("Test Case"))
    }

    @Test("Markdown report includes regressions")
    func testMarkdownRegressions() {
        let comparison = BaselineComparison(
            baselineRunId: "baseline-1",
            currentRunId: "current-1",
            timestamp: Date(),
            caseComparisons: [],
            regressions: [
                MetricRegression(
                    metric: "entityRecall", baselineValue: 1.0,
                    currentValue: 0.5, delta: -0.5, threshold: 0.1
                )
            ],
            improvements: [],
            passesBaseline: false
        )

        let report = BenchmarkReport(
            runId: "regression-test", timestamp: Date(), engineVersion: "1.0.0",
            results: [],
            summary: BenchmarkSummary(
                totalCases: 0, succeeded: 0, failed: 0,
                expectationsMet: 0, expectationsViolated: 0,
                averageEntityRecall: 0, averageRelationshipRecall: 0,
                averagePredicateRecall: 0, averageGroundingCoverage: 0,
                averageEvidenceCount: 0, averageContextUnitCount: 0,
                averageCompressionRatio: 0, averageRetrievalLatency: 0,
                averageAssemblyLatency: 0, averageReasoningLatency: 0,
                averageTotalLatency: 0, averageBudgetUtilization: 0,
                averageContentLength: 0,
                completenessDistribution: [:],
                totalMissingEntities: 0, totalMissingRelationships: 0,
                categoryScores: [:]
            ),
            comparison: comparison
        )

        let md = BenchmarkReportFormatter.formatMarkdown(report)

        #expect(md.contains("**FAIL**"))
        #expect(md.contains("Regressions"))
        #expect(md.contains("entityRecall"))
    }

    @Test("Markdown report includes improvements")
    func testMarkdownImprovements() {
        let comparison = BaselineComparison(
            baselineRunId: "baseline-1",
            currentRunId: "current-1",
            timestamp: Date(),
            caseComparisons: [],
            regressions: [],
            improvements: [
                MetricImprovement(
                    metric: "groundingCoverage", baselineValue: 0.3,
                    currentValue: 0.8, delta: 0.5
                )
            ],
            passesBaseline: true
        )

        let report = BenchmarkReport(
            runId: "improvement-test", timestamp: Date(), engineVersion: "1.0.0",
            results: [],
            summary: BenchmarkSummary(
                totalCases: 0, succeeded: 0, failed: 0,
                expectationsMet: 0, expectationsViolated: 0,
                averageEntityRecall: 0, averageRelationshipRecall: 0,
                averagePredicateRecall: 0, averageGroundingCoverage: 0,
                averageEvidenceCount: 0, averageContextUnitCount: 0,
                averageCompressionRatio: 0, averageRetrievalLatency: 0,
                averageAssemblyLatency: 0, averageReasoningLatency: 0,
                averageTotalLatency: 0, averageBudgetUtilization: 0,
                averageContentLength: 0,
                completenessDistribution: [:],
                totalMissingEntities: 0, totalMissingRelationships: 0,
                categoryScores: [:]
            ),
            comparison: comparison
        )

        let md = BenchmarkReportFormatter.formatMarkdown(report)

        #expect(md.contains("**PASS**"))
        #expect(md.contains("Improvements"))
        #expect(md.contains("groundingCoverage"))
    }

    @Test("Markdown report shows per-case metrics")
    func testMarkdownPerCase() {
        let metrics = BenchmarkMetrics(
            retrievalLatency: 0.005, contextAssemblyLatency: 0.002,
            reasoningLatency: 0.010, totalLatency: 0.020,
            evidenceUnitCount: 10, contextUnitCount: 8,
            unusedEvidence: 2, compressionRatio: 0.8,
            evidenceByStage: ["direct": 10], evidenceByTier: ["t0": 10],
            entityRecall: 0.5, foundEntities: ["A"],
            missingEntities: ["B", "C"],
            relationshipRecall: 1.0, foundRelationships: [],
            missingRelationships: [],
            predicateRecall: 1.0, foundPredicates: ["kind"],
            missingPredicates: [],
            groundingCoverage: 0.6, totalClaims: 3,
            claimTypeDistribution: ["factual": 3],
            completeness: "complete", degradationLevel: "full",
            budgetUtilization: 0.4, contentLength: 200,
            stratumDistribution: ["primary": 8],
            engineIdentifier: "com.decode.explain", engineVersion: "1.0.0"
        )

        let result = BenchmarkResult(
            caseId: "detail-case", caseName: "Detail Test",
            category: "entityDiscovery", timestamp: Date(),
            success: true, metrics: metrics,
            violations: [
                ExpectationViolation(
                    expectation: "all entities found",
                    actual: "missing B, C",
                    description: "2 expected entities not found"
                )
            ],
            error: nil, failureStage: nil
        )

        let report = BenchmarkReport(
            runId: "detail-test", timestamp: Date(), engineVersion: "1.0.0",
            results: [result],
            summary: BenchmarkSummary(
                totalCases: 1, succeeded: 1, failed: 0,
                expectationsMet: 0, expectationsViolated: 1,
                averageEntityRecall: 0.5, averageRelationshipRecall: 1.0,
                averagePredicateRecall: 1.0, averageGroundingCoverage: 0.6,
                averageEvidenceCount: 10, averageContextUnitCount: 8,
                averageCompressionRatio: 0.8, averageRetrievalLatency: 0.005,
                averageAssemblyLatency: 0.002, averageReasoningLatency: 0.010,
                averageTotalLatency: 0.020, averageBudgetUtilization: 0.4,
                averageContentLength: 200,
                completenessDistribution: ["complete": 1],
                totalMissingEntities: 2, totalMissingRelationships: 0,
                categoryScores: [:]
            ),
            comparison: nil
        )

        let md = BenchmarkReportFormatter.formatMarkdown(report)

        #expect(md.contains("Detail Test"))
        #expect(md.contains("Evidence units"))
        #expect(md.contains("Missing entities"))
        #expect(md.contains("B, C"))
        #expect(md.contains("Violations"))
    }

    @Test("Markdown report handles failed case")
    func testMarkdownFailedCase() {
        let result = BenchmarkResult(
            caseId: "failed-case", caseName: "Failed Case",
            category: "edgeCase", timestamp: Date(),
            success: false, metrics: nil,
            violations: [],
            error: "No evidence found for entity 'Unknown'",
            failureStage: "retrieval"
        )

        let report = BenchmarkReport(
            runId: "failed-test", timestamp: Date(), engineVersion: "1.0.0",
            results: [result],
            summary: BenchmarkSummary(
                totalCases: 1, succeeded: 0, failed: 1,
                expectationsMet: 0, expectationsViolated: 0,
                averageEntityRecall: 0, averageRelationshipRecall: 0,
                averagePredicateRecall: 0, averageGroundingCoverage: 0,
                averageEvidenceCount: 0, averageContextUnitCount: 0,
                averageCompressionRatio: 0, averageRetrievalLatency: 0,
                averageAssemblyLatency: 0, averageReasoningLatency: 0,
                averageTotalLatency: 0, averageBudgetUtilization: 0,
                averageContentLength: 0,
                completenessDistribution: [:],
                totalMissingEntities: 0, totalMissingRelationships: 0,
                categoryScores: [:]
            ),
            comparison: nil
        )

        let md = BenchmarkReportFormatter.formatMarkdown(report)

        #expect(md.contains("FAIL"))
        #expect(md.contains("No evidence found"))
        #expect(md.contains("retrieval"))
    }
}

// MARK: - Benchmark Expectations Tests

@Suite("BenchmarkExpectations")
struct BenchmarkExpectationsTests {

    @Test("Default expectations")
    func testDefaultExpectations() {
        let expectations = BenchmarkExpectations()

        #expect(expectations.expectedEntities.isEmpty)
        #expect(expectations.expectedRelationships.isEmpty)
        #expect(expectations.expectedPredicates.isEmpty)
        #expect(expectations.minEvidenceCount == nil)
        #expect(expectations.maxEvidenceCount == nil)
        #expect(expectations.requireSuccess == true)
    }

    @Test("Full expectations construction")
    func testFullExpectations() {
        let expectations = BenchmarkExpectations(
            expectedEntities: ["A", "B"],
            expectedRelationships: [
                ExpectedRelationship(source: "A", predicate: "calls", target: "B")
            ],
            expectedPredicates: ["kind", "signature"],
            minEvidenceCount: 5,
            maxEvidenceCount: 50,
            expectedStages: Set(["direct", "relational"]),
            expectedTiers: Set(["t0"]),
            minGroundingCoverage: 0.5,
            expectedCompleteness: .complete,
            requireSuccess: true
        )

        #expect(expectations.expectedEntities.count == 2)
        #expect(expectations.expectedRelationships.count == 1)
        #expect(expectations.expectedPredicates.count == 2)
        #expect(expectations.minEvidenceCount == 5)
        #expect(expectations.maxEvidenceCount == 50)
    }
}

// MARK: - Benchmark Thresholds Tests

@Suite("BenchmarkThresholds")
struct BenchmarkThresholdsTests {

    @Test("Default thresholds are reasonable")
    func testDefaults() {
        let defaults = BenchmarkThresholds.default

        #expect(defaults.entityRecallThreshold == 0.1)
        #expect(defaults.relationshipRecallThreshold == 0.1)
        #expect(defaults.groundingCoverageThreshold == 0.1)
        #expect(defaults.latencyThreshold == 0.5)
        #expect(defaults.compressionThreshold == 0.15)
    }
}

// MARK: - JSON Export Tests

@Suite("BenchmarkJSONExport")
struct BenchmarkJSONExportTests {

    @Test("Full report with metrics round-trips through JSON")
    func testFullReportRoundTrip() throws {
        let metrics = BenchmarkMetrics(
            retrievalLatency: 0.005, contextAssemblyLatency: 0.002,
            reasoningLatency: 0.010, totalLatency: 0.020,
            evidenceUnitCount: 10, contextUnitCount: 8,
            unusedEvidence: 2, compressionRatio: 0.8,
            evidenceByStage: ["direct": 6, "relational": 4],
            evidenceByTier: ["t0": 8, "t1": 2],
            entityRecall: 1.0, foundEntities: ["A", "B"],
            missingEntities: [],
            relationshipRecall: 0.5,
            foundRelationships: ["A -[calls]-> B"],
            missingRelationships: ["A -[conformsTo]-> P"],
            predicateRecall: 1.0, foundPredicates: ["kind"],
            missingPredicates: [],
            groundingCoverage: 0.6, totalClaims: 5,
            claimTypeDistribution: ["factual": 3, "derived": 2],
            completeness: "complete", degradationLevel: "full",
            budgetUtilization: 0.4, contentLength: 500,
            stratumDistribution: ["direct": 6, "relational": 2],
            engineIdentifier: "com.decode.explain", engineVersion: "1.0.0"
        )

        let result = BenchmarkResult(
            caseId: "json-case", caseName: "JSON Case",
            category: "entityDiscovery",
            timestamp: Date(timeIntervalSince1970: 1000),
            success: true, metrics: metrics,
            violations: [], error: nil, failureStage: nil
        )

        let comparison = BaselineComparison(
            baselineRunId: "base", currentRunId: "curr",
            timestamp: Date(timeIntervalSince1970: 2000),
            caseComparisons: [],
            regressions: [
                MetricRegression(metric: "entityRecall", baselineValue: 1.0, currentValue: 0.5, delta: -0.5, threshold: 0.1)
            ],
            improvements: [
                MetricImprovement(metric: "groundingCoverage", baselineValue: 0.3, currentValue: 0.8, delta: 0.5)
            ],
            passesBaseline: false
        )

        let report = BenchmarkReport(
            runId: "json-test",
            timestamp: Date(timeIntervalSince1970: 3000),
            engineVersion: "1.0.0",
            results: [result],
            summary: BenchmarkSummary(
                totalCases: 1, succeeded: 1, failed: 0,
                expectationsMet: 1, expectationsViolated: 0,
                averageEntityRecall: 1.0, averageRelationshipRecall: 0.5,
                averagePredicateRecall: 1.0, averageGroundingCoverage: 0.6,
                averageEvidenceCount: 10, averageContextUnitCount: 8,
                averageCompressionRatio: 0.8, averageRetrievalLatency: 0.005,
                averageAssemblyLatency: 0.002, averageReasoningLatency: 0.010,
                averageTotalLatency: 0.020, averageBudgetUtilization: 0.4,
                averageContentLength: 500,
                completenessDistribution: ["complete": 1],
                totalMissingEntities: 0, totalMissingRelationships: 1,
                categoryScores: [:]
            ),
            comparison: comparison
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BenchmarkReport.self, from: data)

        #expect(decoded.runId == "json-test")
        #expect(decoded.results.count == 1)
        #expect(decoded.results[0].metrics?.entityRecall == 1.0)
        #expect(decoded.comparison?.passesBaseline == false)
        #expect(decoded.comparison?.regressions.count == 1)
    }

    @Test("JSON output is human-readable")
    func testPrettyJSON() throws {
        let report = BenchmarkReport(
            runId: "pretty-test",
            timestamp: Date(timeIntervalSince1970: 1000),
            engineVersion: "1.0.0",
            results: [],
            summary: BenchmarkSummary(
                totalCases: 0, succeeded: 0, failed: 0,
                expectationsMet: 0, expectationsViolated: 0,
                averageEntityRecall: 0, averageRelationshipRecall: 0,
                averagePredicateRecall: 0, averageGroundingCoverage: 0,
                averageEvidenceCount: 0, averageContextUnitCount: 0,
                averageCompressionRatio: 0, averageRetrievalLatency: 0,
                averageAssemblyLatency: 0, averageReasoningLatency: 0,
                averageTotalLatency: 0, averageBudgetUtilization: 0,
                averageContentLength: 0,
                completenessDistribution: [:],
                totalMissingEntities: 0, totalMissingRelationships: 0,
                categoryScores: [:]
            ),
            comparison: nil
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("\"runId\""))
        #expect(json.contains("pretty-test"))
        #expect(json.contains("\"summary\""))
    }
}

// MARK: - Benchmark Runner Unit Tests (without pipeline)

@Suite("BenchmarkRunnerUnit")
struct BenchmarkRunnerUnitTests {

    @Test("BenchmarkSourceFile construction")
    func testSourceFile() {
        let file = BenchmarkSourceFile(
            fileName: "Service.swift",
            content: "class UserService { func fetch() {} }"
        )

        #expect(file.fileName == "Service.swift")
        #expect(file.content.contains("UserService"))
    }

    @Test("ExpectedRelationship construction")
    func testExpectedRelationship() {
        let rel = ExpectedRelationship(
            source: "Controller",
            predicate: "calls",
            target: "Service"
        )

        #expect(rel.source == "Controller")
        #expect(rel.predicate == "calls")
        #expect(rel.target == "Service")
    }

    @Test("BenchmarkResult failure with stage")
    func testFailureResult() {
        let result = BenchmarkResult(
            caseId: "fail-case",
            caseName: "Failure Test",
            category: "edgeCase",
            timestamp: Date(),
            success: false,
            metrics: nil,
            violations: [],
            error: "No evidence found",
            failureStage: "retrieval"
        )

        #expect(!result.success)
        #expect(result.failureStage == "retrieval")
        #expect(result.metrics == nil)
    }
}

// MARK: - Benchmark Corpus Tests

@Suite("BenchmarkCorpus")
struct BenchmarkCorpusTests {

    @Test("Corpus contains at least 20 cases")
    func testCorpusSize() {
        #expect(BenchmarkCorpus.allCases.count >= 20)
    }

    @Test("All case IDs are unique")
    func testUniqueIds() {
        let ids = BenchmarkCorpus.allCases.map(\.id)
        let uniqueIds = Set(ids)
        #expect(ids.count == uniqueIds.count, "Duplicate benchmark IDs found")
    }

    @Test("All case names are unique")
    func testUniqueNames() {
        let names = BenchmarkCorpus.allCases.map(\.name)
        let uniqueNames = Set(names)
        #expect(names.count == uniqueNames.count, "Duplicate benchmark names found")
    }

    @Test("Every category has at least one case")
    func testCategoryCoverage() {
        let covered = BenchmarkCorpus.coveredCategories
        for category in BenchmarkCategory.allCases {
            #expect(covered.contains(category), "No cases for category: \(category.rawValue)")
        }
    }

    @Test("Category filter returns correct cases")
    func testCategoryFilter() {
        for category in BenchmarkCategory.allCases {
            let cases = BenchmarkCorpus.cases(for: category)
            for c in cases {
                #expect(c.category == category)
            }
        }
    }

    @Test("Find by ID returns correct case")
    func testFindById() {
        let found = BenchmarkCorpus.findCase(id: "sf-01-simple-class")
        #expect(found != nil)
        #expect(found?.name == "Simple Swift Class")

        let notFound = BenchmarkCorpus.findCase(id: "nonexistent")
        #expect(notFound == nil)
    }

    @Test("All cases have at least one source file")
    func testSourceFiles() {
        for benchCase in BenchmarkCorpus.allCases {
            #expect(!benchCase.sourceFiles.isEmpty, "Case \(benchCase.id) has no source files")
            for file in benchCase.sourceFiles {
                #expect(!file.fileName.isEmpty, "Case \(benchCase.id) has empty file name")
                #expect(!file.content.isEmpty, "Case \(benchCase.id) has empty content for \(file.fileName)")
            }
        }
    }

    @Test("All cases have non-empty query entity")
    func testQueryEntities() {
        for benchCase in BenchmarkCorpus.allCases {
            #expect(!benchCase.queryEntity.isEmpty, "Case \(benchCase.id) has empty query entity")
        }
    }

    @Test("All cases have expected entities")
    func testExpectations() {
        for benchCase in BenchmarkCorpus.allCases {
            #expect(!benchCase.expectations.expectedEntities.isEmpty,
                    "Case \(benchCase.id) has no expected entities")
        }
    }

    @Test("Cases are ordered by category then difficulty")
    func testOrdering() {
        // Verify cases within each category are contiguous
        var seenCategories = Set<BenchmarkCategory>()
        var lastCategory: BenchmarkCategory?
        for benchCase in BenchmarkCorpus.allCases {
            if benchCase.category != lastCategory {
                #expect(!seenCategories.contains(benchCase.category),
                        "Category \(benchCase.category.rawValue) is not contiguous")
                seenCategories.insert(benchCase.category)
                lastCategory = benchCase.category
            }
        }
    }

    @Test("IDs follow naming convention")
    func testIdNamingConvention() {
        let prefixes = ["sf-", "rel-", "cf-", "df-", "di-", "arch-", "edge-"]
        for benchCase in BenchmarkCorpus.allCases {
            let hasValidPrefix = prefixes.contains { benchCase.id.hasPrefix($0) }
            #expect(hasValidPrefix, "Case \(benchCase.id) doesn't follow naming convention")
        }
    }

    @Test("Cross-file cases have multiple source files")
    func testCrossFileCasesMultiFile() {
        let crossFileCases = BenchmarkCorpus.cases(for: .crossFileResolution)
        for benchCase in crossFileCases {
            #expect(benchCase.sourceFiles.count >= 2,
                    "Cross-file case \(benchCase.id) should have multiple source files")
        }
    }

    @Test("Relationship cases have expected relationships")
    func testRelationshipCasesHaveRelationships() {
        let relCases = BenchmarkCorpus.cases(for: .relationshipResolution)
        for benchCase in relCases {
            #expect(!benchCase.expectations.expectedRelationships.isEmpty,
                    "Relationship case \(benchCase.id) should have expected relationships")
        }
    }
}

// MARK: - Category Score Tests

@Suite("CategoryScore")
struct CategoryScoreTests {

    @Test("Composite score calculation")
    func testCompositeScore() {
        let score = CategoryScore(
            caseCount: 5,
            succeeded: 5,
            expectationsMet: 5,
            averageEntityRecall: 1.0,
            averageRelationshipRecall: 1.0,
            averageGroundingCoverage: 1.0
        )

        // 1.0 * 0.4 + 1.0 * 0.3 + 1.0 * 0.2 + 1.0 * 0.1 = 1.0
        #expect(abs(score.compositeScore - 1.0) < 0.001)
    }

    @Test("Composite score with partial values")
    func testPartialCompositeScore() {
        let score = CategoryScore(
            caseCount: 10,
            succeeded: 8,
            expectationsMet: 6,
            averageEntityRecall: 0.8,
            averageRelationshipRecall: 0.5,
            averageGroundingCoverage: 0.6
        )

        // 0.8 * 0.4 + 0.5 * 0.3 + 0.6 * 0.2 + 0.8 * 0.1 = 0.32 + 0.15 + 0.12 + 0.08 = 0.67
        let expected = 0.8 * 0.4 + 0.5 * 0.3 + 0.6 * 0.2 + 0.8 * 0.1
        #expect(abs(score.compositeScore - expected) < 0.001)
    }

    @Test("Zero case count produces zero score")
    func testZeroCases() {
        let score = CategoryScore(
            caseCount: 0,
            succeeded: 0,
            expectationsMet: 0,
            averageEntityRecall: 0,
            averageRelationshipRecall: 0,
            averageGroundingCoverage: 0
        )

        #expect(score.compositeScore == 0.0)
    }

    @Test("CategoryScore is Codable")
    func testCodable() throws {
        let score = CategoryScore(
            caseCount: 3,
            succeeded: 2,
            expectationsMet: 2,
            averageEntityRecall: 0.9,
            averageRelationshipRecall: 0.7,
            averageGroundingCoverage: 0.8
        )

        let data = try JSONEncoder().encode(score)
        let decoded = try JSONDecoder().decode(CategoryScore.self, from: data)

        #expect(decoded.caseCount == 3)
        #expect(decoded.averageEntityRecall == 0.9)
    }
}

// MARK: - Report Formatter Category Scores Tests

@Suite("BenchmarkReportFormatterCategories")
struct BenchmarkReportFormatterCategoryTests {

    @Test("Markdown report includes category scores table")
    func testCategoryScoresInReport() {
        let report = BenchmarkReport(
            runId: "cat-test",
            timestamp: Date(timeIntervalSince1970: 1000),
            engineVersion: "1.0.0",
            results: [],
            summary: BenchmarkSummary(
                totalCases: 5, succeeded: 5, failed: 0,
                expectationsMet: 4, expectationsViolated: 1,
                averageEntityRecall: 0.9, averageRelationshipRecall: 0.8,
                averagePredicateRecall: 1.0, averageGroundingCoverage: 0.7,
                averageEvidenceCount: 8, averageContextUnitCount: 6,
                averageCompressionRatio: 0.75, averageRetrievalLatency: 0.003,
                averageAssemblyLatency: 0.002, averageReasoningLatency: 0.005,
                averageTotalLatency: 0.01, averageBudgetUtilization: 0.4,
                averageContentLength: 300,
                completenessDistribution: ["complete": 5],
                totalMissingEntities: 1, totalMissingRelationships: 0,
                categoryScores: [
                    "entityDiscovery": CategoryScore(
                        caseCount: 3, succeeded: 3, expectationsMet: 3,
                        averageEntityRecall: 1.0, averageRelationshipRecall: 1.0,
                        averageGroundingCoverage: 0.8
                    ),
                    "relationshipResolution": CategoryScore(
                        caseCount: 2, succeeded: 2, expectationsMet: 1,
                        averageEntityRecall: 0.8, averageRelationshipRecall: 0.6,
                        averageGroundingCoverage: 0.5
                    )
                ]
            ),
            comparison: nil
        )

        let md = BenchmarkReportFormatter.formatMarkdown(report)

        #expect(md.contains("Category Scores"))
        #expect(md.contains("entityDiscovery"))
        #expect(md.contains("relationshipResolution"))
        #expect(md.contains("Total Score"))
        #expect(md.contains("Score"))
    }

    @Test("Total score is average of category composite scores")
    func testTotalScoreCalculation() {
        let cat1 = CategoryScore(
            caseCount: 2, succeeded: 2, expectationsMet: 2,
            averageEntityRecall: 1.0, averageRelationshipRecall: 1.0,
            averageGroundingCoverage: 1.0
        )
        let cat2 = CategoryScore(
            caseCount: 2, succeeded: 2, expectationsMet: 2,
            averageEntityRecall: 0.5, averageRelationshipRecall: 0.5,
            averageGroundingCoverage: 0.5
        )

        // cat1 composite = 1.0, cat2 composite = 0.5*0.4 + 0.5*0.3 + 0.5*0.2 + 1.0*0.1 = 0.55
        // avg = (1.0 + 0.55) / 2 = 0.775
        let report = BenchmarkReport(
            runId: "score-test",
            timestamp: Date(timeIntervalSince1970: 1000),
            engineVersion: "1.0.0",
            results: [],
            summary: BenchmarkSummary(
                totalCases: 4, succeeded: 4, failed: 0,
                expectationsMet: 4, expectationsViolated: 0,
                averageEntityRecall: 0.75, averageRelationshipRecall: 0.75,
                averagePredicateRecall: 1.0, averageGroundingCoverage: 0.75,
                averageEvidenceCount: 8, averageContextUnitCount: 6,
                averageCompressionRatio: 0.75, averageRetrievalLatency: 0.003,
                averageAssemblyLatency: 0.002, averageReasoningLatency: 0.005,
                averageTotalLatency: 0.01, averageBudgetUtilization: 0.4,
                averageContentLength: 300,
                completenessDistribution: ["complete": 4],
                totalMissingEntities: 0, totalMissingRelationships: 0,
                categoryScores: ["a": cat1, "b": cat2]
            ),
            comparison: nil
        )

        let md = BenchmarkReportFormatter.formatMarkdown(report)
        #expect(md.contains("Total Score"))
    }
}
