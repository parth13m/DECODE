// EvaluationFrameworkTests.swift — DecodeTests
// E1-01: Tests for the Explanation Quality Baseline evaluation framework.
//
// Verifies: metric extraction, expectation checking, report generation,
// baseline comparison, regression detection, and JSON serialization.

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

private func makeRelationshipUnit(
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

private func makeFrame(
    units: [AtomicUnit],
    purpose: ContextPurpose = ContextPurpose("explain"),
    budget: Int = 1000
) -> ContextFrame {
    let contextUnits = units.map { unit in
        ContextUnit(
            annotatedUnit: AnnotatedUnit(
                unit: unit,
                provenance: EvidenceProvenance(stage: .direct, path: ["direct"]),
                distance: 0
            ),
            role: ContextRole(stratumName: "primary", reason: "test")
        )
    }

    let stratum = FilledStratum(
        name: "primary",
        priority: 0,
        units: contextUnits,
        budgetAllocated: budget,
        budgetUsed: units.count
    )

    let tierCounts: [Tier: Int] = Dictionary(
        units.map { ($0.tier, 1) },
        uniquingKeysWith: +
    )

    return ContextFrame(
        anchors: units.compactMap { unit in
            if case .entity(let ref) = unit.subject { return ref }
            return nil
        },
        purpose: purpose,
        strategyVersion: "test-1.0",
        strata: [stratum],
        budgetSummary: BudgetSummary(total: budget, denomination: .unitCount, used: units.count),
        metadata: ContextFrameMetadata(
            evidenceSetSize: units.count,
            selectedCount: units.count,
            tierCounts: tierCounts,
            stratumCounts: ["primary": units.count],
            coherenceStatistics: CoherenceStatistics(fired: 0, satisfied: 0, retracted: 0),
            degradationLevel: .full,
            freshnessState: .fresh,
            assemblyDuration: 0.001,
            strategyVersion: "test-1.0",
            committedEpoch: Epoch(value: 1),
            budgetInsufficient: false
        )
    )
}

private func makeMultiStratumFrame(
    primaryUnits: [AtomicUnit],
    relationalUnits: [AtomicUnit],
    budget: Int = 1000
) -> ContextFrame {
    let primaryContextUnits = primaryUnits.map { unit in
        ContextUnit(
            annotatedUnit: AnnotatedUnit(
                unit: unit,
                provenance: EvidenceProvenance(stage: .direct, path: ["direct"]),
                distance: 0
            ),
            role: ContextRole(stratumName: "direct", reason: "anchor")
        )
    }
    let relationalContextUnits = relationalUnits.map { unit in
        ContextUnit(
            annotatedUnit: AnnotatedUnit(
                unit: unit,
                provenance: EvidenceProvenance(stage: .relational, path: ["relational"]),
                distance: 1
            ),
            role: ContextRole(stratumName: "relational", reason: "related")
        )
    }

    let allUnits = primaryUnits + relationalUnits
    let totalCount = allUnits.count
    let tierCounts: [Tier: Int] = Dictionary(
        allUnits.map { ($0.tier, 1) },
        uniquingKeysWith: +
    )

    return ContextFrame(
        anchors: primaryUnits.compactMap { unit in
            if case .entity(let ref) = unit.subject { return ref }
            return nil
        },
        purpose: ContextPurpose("explain"),
        strategyVersion: "test-1.0",
        strata: [
            FilledStratum(
                name: "direct",
                priority: 0,
                units: primaryContextUnits,
                budgetAllocated: budget / 2,
                budgetUsed: primaryUnits.count
            ),
            FilledStratum(
                name: "relational",
                priority: 1,
                units: relationalContextUnits,
                budgetAllocated: budget / 2,
                budgetUsed: relationalUnits.count
            )
        ],
        budgetSummary: BudgetSummary(total: budget, denomination: .unitCount, used: totalCount),
        metadata: ContextFrameMetadata(
            evidenceSetSize: totalCount,
            selectedCount: totalCount,
            tierCounts: tierCounts,
            stratumCounts: ["direct": primaryUnits.count, "relational": relationalUnits.count],
            coherenceStatistics: CoherenceStatistics(fired: 0, satisfied: 0, retracted: 0),
            degradationLevel: .full,
            freshnessState: .fresh,
            assemblyDuration: 0.002,
            strategyVersion: "test-1.0",
            committedEpoch: Epoch(value: 1),
            budgetInsufficient: false
        )
    )
}

private func makeDeterministicEngine() -> ExplainReasoningEngine {
    ExplainReasoningEngine(aiProvider: { nil })
}

private func makeCase(
    id: String,
    name: String,
    category: EvaluationCategory,
    frame: ContextFrame,
    expectations: QualityExpectations? = nil
) -> EvaluationCase {
    EvaluationCase(
        id: id,
        name: name,
        description: "Test case: \(name)",
        category: category,
        contextFrame: frame,
        outputSpecification: OutputSpecification(
            purpose: ContextPurpose("explain"),
            outputClass: .human,
            detailLevel: .standard
        ),
        expectations: expectations
    )
}

// MARK: - Evaluation Runner Tests

@Suite("EvaluationRunner")
struct EvaluationRunnerTests {

    @Test("Runner produces report for single case")
    func testSingleCase() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units = [
            makeUnit(id: 1, entityName: "AppDelegate", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "AppDelegate", predicateName: "conformsTo", value: .string("NSApplicationDelegate")),
        ]
        let frame = makeFrame(units: units)
        let evalCase = makeCase(id: "single-class", name: "Single Class Entity", category: .singleEntity, frame: frame)

        let report = await runner.run(cases: [evalCase], runId: "test-run-1")

        #expect(report.runId == "test-run-1")
        #expect(report.results.count == 1)
        #expect(report.results[0].success)
        #expect(report.results[0].caseId == "single-class")
        #expect(report.results[0].metrics != nil)
        #expect(report.summary.totalCases == 1)
        #expect(report.summary.succeeded == 1)
        #expect(report.summary.failed == 0)
    }

    @Test("Runner captures grounding metrics")
    func testGroundingMetrics() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("struct")),
            makeUnit(id: 2, entityName: "UserService", predicateName: "hasMethod", value: .string("fetchUser")),
        ]
        let frame = makeFrame(units: units)
        let evalCase = makeCase(id: "grounding", name: "Grounding Test", category: .singleEntity, frame: frame)

        let report = await runner.run(cases: [evalCase])
        let metrics = report.results[0].metrics!

        #expect(metrics.totalClaims > 0)
        #expect(metrics.groundedClaims == metrics.totalClaims)
        #expect(metrics.groundingCoverage > 0.0)
        #expect(metrics.completeness == "partial") // deterministic fallback = partial
    }

    @Test("Runner captures context metrics")
    func testContextMetrics() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units = [
            makeUnit(id: 1, entityName: "A", predicateName: "kind", value: .string("class"), tier: .t0),
            makeUnit(id: 2, entityName: "B", predicateName: "kind", value: .string("struct"), tier: .t1),
        ]
        let frame = makeFrame(units: units)
        let evalCase = makeCase(id: "context", name: "Context Metrics", category: .multiEntity, frame: frame)

        let report = await runner.run(cases: [evalCase])
        let metrics = report.results[0].metrics!

        #expect(metrics.evidenceSetSize == 2)
        #expect(metrics.selectedCount == 2)
        #expect(metrics.elisionRatio == 0.0)
        #expect(metrics.tierDistribution["t0"] == 1)
        #expect(metrics.tierDistribution["t1"] == 1)
        #expect(metrics.degradationLevel == "full")
        #expect(metrics.budgetTotal == 1000)
        #expect(metrics.budgetUsed == 2)
    }

    @Test("Runner captures engine metadata")
    func testEngineMetadata() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: "com.decode.explain",
            engineVersion: "1.0.0"
        )

        let units = [makeUnit(id: 1, entityName: "X", predicateName: "kind", value: .string("enum"))]
        let frame = makeFrame(units: units)
        let evalCase = makeCase(id: "engine-meta", name: "Engine Metadata", category: .singleEntity, frame: frame)

        let report = await runner.run(cases: [evalCase])
        let metrics = report.results[0].metrics!

        #expect(metrics.engineIdentifier == "com.decode.explain")
        #expect(metrics.engineVersion == "1.0.0")
        #expect(metrics.usedFallback == false)
        #expect(metrics.isStale == false)
    }

    @Test("Runner handles empty context frame")
    func testEmptyContextFrame() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let frame = makeFrame(units: [])
        let evalCase = makeCase(id: "empty", name: "Empty Frame", category: .edgeCase, frame: frame)

        let report = await runner.run(cases: [evalCase])

        #expect(report.results[0].success)
        let metrics = report.results[0].metrics!
        #expect(metrics.totalClaims == 0)
        #expect(metrics.completeness == "insufficient")
        #expect(metrics.contentLength > 0) // "Insufficient evidence" message
    }

    @Test("Runner handles multiple cases")
    func testMultipleCases() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let cases = [
            makeCase(
                id: "case-1", name: "Case 1", category: .singleEntity,
                frame: makeFrame(units: [
                    makeUnit(id: 1, entityName: "A", predicateName: "kind", value: .string("class"))
                ])
            ),
            makeCase(
                id: "case-2", name: "Case 2", category: .multiEntity,
                frame: makeFrame(units: [
                    makeUnit(id: 10, entityName: "B", predicateName: "kind", value: .string("struct")),
                    makeUnit(id: 11, entityName: "C", predicateName: "kind", value: .string("enum")),
                ])
            ),
            makeCase(
                id: "case-3", name: "Case 3", category: .edgeCase,
                frame: makeFrame(units: [])
            ),
        ]

        let report = await runner.run(cases: cases)

        #expect(report.summary.totalCases == 3)
        #expect(report.summary.succeeded == 3)
        #expect(report.results.count == 3)
        #expect(report.results[0].caseId == "case-1")
        #expect(report.results[1].caseId == "case-2")
        #expect(report.results[2].caseId == "case-3")
    }

    @Test("Runner captures relationship metrics")
    func testRelationshipMetrics() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "Controller", predicateName: "kind", value: .string("class")),
            makeRelationshipUnit(id: 2, source: "Controller", target: "Service", predicate: "calls"),
            makeRelationshipUnit(id: 3, source: "Controller", target: "Repository", predicate: "calls"),
        ]
        let frame = makeFrame(units: units)
        let evalCase = makeCase(id: "rels", name: "Relationships", category: .relationships, frame: frame)

        let report = await runner.run(cases: [evalCase])
        let metrics = report.results[0].metrics!

        #expect(metrics.totalClaims > 0)
        #expect(metrics.evidenceSetSize == 3)
        #expect(metrics.contentLength > 0)
    }

    @Test("Runner captures multi-stratum distribution")
    func testMultiStratumMetrics() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let primaryUnits = [
            makeUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
        ]
        let relationalUnits = [
            makeUnit(id: 10, entityName: "Repository", predicateName: "kind", value: .string("protocol")),
        ]
        let frame = makeMultiStratumFrame(primaryUnits: primaryUnits, relationalUnits: relationalUnits)
        let evalCase = makeCase(id: "multi-stratum", name: "Multi-Stratum", category: .crossFile, frame: frame)

        let report = await runner.run(cases: [evalCase])
        let metrics = report.results[0].metrics!

        #expect(metrics.stratumDistribution["direct"] == 1)
        #expect(metrics.stratumDistribution["relational"] == 1)
    }
}

// MARK: - Expectation Tests

@Suite("QualityExpectations")
struct QualityExpectationTests {

    @Test("Met expectations produce no violations")
    func testExpectationsMet() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units = [
            makeUnit(id: 1, entityName: "X", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "X", predicateName: "hasMethod", value: .string("run")),
        ]
        let frame = makeFrame(units: units)
        let evalCase = makeCase(
            id: "met", name: "Expectations Met", category: .singleEntity,
            frame: frame,
            expectations: QualityExpectations(
                minGroundingCoverage: 0.0,
                minClaimCount: 1,
                expectedCompleteness: .partial,
                requireNonEmptyContent: true
            )
        )

        let report = await runner.run(cases: [evalCase])
        #expect(report.results[0].violations.isEmpty)
        #expect(report.summary.expectationsMet == 1)
        #expect(report.summary.expectationsViolated == 0)
    }

    @Test("Violated completeness expectation is reported")
    func testCompletenessViolation() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units = [
            makeUnit(id: 1, entityName: "X", predicateName: "kind", value: .string("class")),
        ]
        let frame = makeFrame(units: units)
        // Deterministic engine produces .partial — expect .complete to trigger violation
        let evalCase = makeCase(
            id: "violated", name: "Completeness Violated", category: .singleEntity,
            frame: frame,
            expectations: QualityExpectations(expectedCompleteness: .complete)
        )

        let report = await runner.run(cases: [evalCase])
        #expect(!report.results[0].violations.isEmpty)
        #expect(report.results[0].violations[0].expectation.contains("completeness"))
        #expect(report.summary.expectationsViolated == 1)
    }

    @Test("Violated claim count expectation is reported")
    func testClaimCountViolation() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        // Empty frame → 0 claims
        let frame = makeFrame(units: [])
        let evalCase = makeCase(
            id: "claim-violated", name: "Claim Count Violated", category: .edgeCase,
            frame: frame,
            expectations: QualityExpectations(minClaimCount: 5)
        )

        let report = await runner.run(cases: [evalCase])
        let violations = report.results[0].violations
        #expect(violations.contains { $0.expectation.contains("totalClaims") })
    }
}

// MARK: - Baseline Comparison Tests

@Suite("BaselineComparator")
struct BaselineComparatorTests {

    private func makeMetrics(
        groundingCoverage: Double = 0.5,
        totalClaims: Int = 5,
        contentLength: Int = 200,
        budgetUtilization: Double = 0.3,
        completeness: String = "partial"
    ) -> EvaluationMetrics {
        EvaluationMetrics(
            groundingCoverage: groundingCoverage,
            totalClaims: totalClaims,
            groundedClaims: totalClaims,
            ungroundedClaimsRemoved: 0,
            confidenceAdjustments: 0,
            claimTypeDistribution: ["factual": totalClaims],
            evidenceSetSize: 10,
            selectedCount: 10,
            elisionRatio: 0.0,
            tierDistribution: ["t0": 10],
            stratumDistribution: ["primary": 10],
            degradationLevel: "full",
            budgetUtilization: budgetUtilization,
            budgetTotal: 1000,
            budgetUsed: 10,
            completeness: completeness,
            reasoningDuration: 0.01,
            contentLength: contentLength,
            entityCount: 2,
            engineIdentifier: "com.decode.explain",
            engineVersion: "1.0.0",
            usedFallback: false,
            isStale: false,
            conversationStateDiscarded: false
        )
    }

    private func makeReport(
        runId: String,
        results: [EvaluationResult],
        avgGrounding: Double = 0.5,
        avgClaims: Double = 5.0
    ) -> EvaluationReport {
        EvaluationReport(
            runId: runId,
            timestamp: Date(),
            engineVersion: "1.0.0",
            results: results,
            summary: EvaluationSummary(
                totalCases: results.count,
                succeeded: results.count,
                failed: 0,
                expectationsMet: results.count,
                expectationsViolated: 0,
                averageGroundingCoverage: avgGrounding,
                averageClaimCount: avgClaims,
                averageContentLength: 200,
                averageReasoningDuration: 0.01,
                averageBudgetUtilization: 0.3,
                completenessDistribution: ["partial": results.count],
                totalClaimTypeDistribution: ["factual": Int(avgClaims) * results.count],
                averageTierDistribution: ["t0": 10.0]
            )
        )
    }

    private func makeResult(
        caseId: String,
        metrics: EvaluationMetrics
    ) -> EvaluationResult {
        EvaluationResult(
            caseId: caseId,
            caseName: caseId,
            category: "singleEntity",
            timestamp: Date(),
            metrics: metrics,
            success: true,
            error: nil,
            violations: []
        )
    }

    @Test("Identical reports show no regressions")
    func testIdenticalReports() {
        let metrics = makeMetrics()
        let result = makeResult(caseId: "case-1", metrics: metrics)
        let baseline = makeReport(runId: "baseline", results: [result])
        let current = makeReport(runId: "current", results: [result])

        let comparator = BaselineComparator()
        let comparison = comparator.compare(baseline: baseline, current: current)

        #expect(comparison.passesBaseline)
        #expect(comparison.regressions.isEmpty)
    }

    @Test("Grounding coverage regression is detected")
    func testGroundingRegression() {
        let baselineMetrics = makeMetrics(groundingCoverage: 0.8)
        let currentMetrics = makeMetrics(groundingCoverage: 0.5)

        let baselineResult = makeResult(caseId: "case-1", metrics: baselineMetrics)
        let currentResult = makeResult(caseId: "case-1", metrics: currentMetrics)

        let baseline = makeReport(runId: "baseline", results: [baselineResult], avgGrounding: 0.8)
        let current = makeReport(runId: "current", results: [currentResult], avgGrounding: 0.5)

        let comparator = BaselineComparator(thresholds: .default)
        let comparison = comparator.compare(baseline: baseline, current: current)

        #expect(!comparison.passesBaseline)
        let groundingRegressions = comparison.regressions.filter { $0.metric.contains("groundingCoverage") }
        #expect(!groundingRegressions.isEmpty)
    }

    @Test("Improvement is detected")
    func testImprovement() {
        let baselineMetrics = makeMetrics(groundingCoverage: 0.3)
        let currentMetrics = makeMetrics(groundingCoverage: 0.8)

        let baselineResult = makeResult(caseId: "case-1", metrics: baselineMetrics)
        let currentResult = makeResult(caseId: "case-1", metrics: currentMetrics)

        let baseline = makeReport(runId: "baseline", results: [baselineResult], avgGrounding: 0.3)
        let current = makeReport(runId: "current", results: [currentResult], avgGrounding: 0.8)

        let comparator = BaselineComparator()
        let comparison = comparator.compare(baseline: baseline, current: current)

        #expect(comparison.passesBaseline)
        let groundingImprovements = comparison.improvements.filter { $0.metric.contains("groundingCoverage") }
        #expect(!groundingImprovements.isEmpty)
    }

    @Test("Small changes within threshold pass baseline")
    func testWithinThreshold() {
        let baselineMetrics = makeMetrics(groundingCoverage: 0.5)
        let currentMetrics = makeMetrics(groundingCoverage: 0.45) // 0.05 drop < 0.1 threshold

        let baselineResult = makeResult(caseId: "case-1", metrics: baselineMetrics)
        let currentResult = makeResult(caseId: "case-1", metrics: currentMetrics)

        let baseline = makeReport(runId: "baseline", results: [baselineResult], avgGrounding: 0.5)
        let current = makeReport(runId: "current", results: [currentResult], avgGrounding: 0.45)

        let comparator = BaselineComparator()
        let comparison = comparator.compare(baseline: baseline, current: current)

        #expect(comparison.passesBaseline)
    }

    @Test("Custom thresholds are respected")
    func testCustomThresholds() {
        let baselineMetrics = makeMetrics(groundingCoverage: 0.5)
        let currentMetrics = makeMetrics(groundingCoverage: 0.45)

        let baselineResult = makeResult(caseId: "case-1", metrics: baselineMetrics)
        let currentResult = makeResult(caseId: "case-1", metrics: currentMetrics)

        let baseline = makeReport(runId: "baseline", results: [baselineResult], avgGrounding: 0.5)
        let current = makeReport(runId: "current", results: [currentResult], avgGrounding: 0.45)

        // Tight threshold: 0.01 — any drop > 1% is a regression
        let tightThresholds = ComparisonThresholds(
            groundingCoverageThreshold: 0.01,
            claimCountThreshold: 0.01,
            contentLengthThreshold: 0.01,
            reasoningDurationThreshold: 0.01,
            budgetUtilizationThreshold: 0.01
        )
        let comparator = BaselineComparator(thresholds: tightThresholds)
        let comparison = comparator.compare(baseline: baseline, current: current)

        #expect(!comparison.passesBaseline)
    }

    @Test("Missing baseline case does not cause regression")
    func testNewCaseWithoutBaseline() {
        let metrics = makeMetrics()
        let currentResult = makeResult(caseId: "new-case", metrics: metrics)
        let baseline = makeReport(runId: "baseline", results: [])
        let current = makeReport(runId: "current", results: [currentResult])

        let comparator = BaselineComparator()
        let comparison = comparator.compare(baseline: baseline, current: current)

        #expect(comparison.passesBaseline)
        #expect(comparison.caseComparisons.count == 1)
        #expect(comparison.caseComparisons[0].baselineMetrics == nil)
    }
}

// MARK: - JSON Serialization Tests

@Suite("EvaluationSerialization")
struct EvaluationSerializationTests {

    @Test("EvaluationMetrics round-trips through JSON")
    func testMetricsRoundTrip() throws {
        let metrics = EvaluationMetrics(
            groundingCoverage: 0.75,
            totalClaims: 8,
            groundedClaims: 7,
            ungroundedClaimsRemoved: 1,
            confidenceAdjustments: 0,
            claimTypeDistribution: ["factual": 5, "derived": 2, "interpretive": 1],
            evidenceSetSize: 20,
            selectedCount: 15,
            elisionRatio: 0.25,
            tierDistribution: ["t0": 10, "t1": 3, "t2": 2],
            stratumDistribution: ["direct": 8, "relational": 5, "module": 2],
            degradationLevel: "full",
            budgetUtilization: 0.6,
            budgetTotal: 500,
            budgetUsed: 300,
            completeness: "complete",
            reasoningDuration: 1.234,
            contentLength: 1500,
            entityCount: 4,
            engineIdentifier: "com.decode.explain",
            engineVersion: "1.0.0",
            usedFallback: false,
            isStale: false,
            conversationStateDiscarded: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(metrics)
        let decoded = try JSONDecoder().decode(EvaluationMetrics.self, from: data)

        #expect(decoded == metrics)
    }

    @Test("EvaluationReport round-trips through JSON")
    func testReportRoundTrip() throws {
        let result = EvaluationResult(
            caseId: "test-case",
            caseName: "Test Case",
            category: "singleEntity",
            timestamp: Date(timeIntervalSince1970: 1000),
            metrics: nil,
            success: true,
            error: nil,
            violations: [
                ExpectationViolation(
                    expectation: "minClaims >= 5",
                    actual: "3",
                    description: "Claim count below minimum"
                )
            ]
        )

        let report = EvaluationReport(
            runId: "run-123",
            timestamp: Date(timeIntervalSince1970: 2000),
            engineVersion: "1.0.0",
            results: [result],
            summary: EvaluationSummary(
                totalCases: 1,
                succeeded: 1,
                failed: 0,
                expectationsMet: 0,
                expectationsViolated: 1,
                averageGroundingCoverage: 0.5,
                averageClaimCount: 3.0,
                averageContentLength: 150.0,
                averageReasoningDuration: 0.5,
                averageBudgetUtilization: 0.3,
                completenessDistribution: ["partial": 1],
                totalClaimTypeDistribution: ["factual": 3],
                averageTierDistribution: ["t0": 5.0]
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(EvaluationReport.self, from: data)

        #expect(decoded.runId == report.runId)
        #expect(decoded.results.count == 1)
        #expect(decoded.results[0].violations.count == 1)
        #expect(decoded.summary.totalCases == 1)
    }

    @Test("BaselineComparison round-trips through JSON")
    func testComparisonRoundTrip() throws {
        let comparison = BaselineComparison(
            baselineRunId: "baseline-1",
            currentRunId: "current-1",
            timestamp: Date(timeIntervalSince1970: 3000),
            caseComparisons: [],
            regressions: [
                MetricRegression(
                    metric: "groundingCoverage",
                    baselineValue: 0.8,
                    currentValue: 0.5,
                    delta: -0.3,
                    threshold: 0.1
                )
            ],
            improvements: [],
            passesBaseline: false
        )

        let data = try JSONEncoder().encode(comparison)
        let decoded = try JSONDecoder().decode(BaselineComparison.self, from: data)

        #expect(decoded.passesBaseline == false)
        #expect(decoded.regressions.count == 1)
        #expect(decoded.regressions[0].metric == "groundingCoverage")
    }
}

// MARK: - Summary Computation Tests

@Suite("EvaluationSummary")
struct EvaluationSummaryTests {

    @Test("Summary aggregates across cases correctly")
    func testSummaryAggregation() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let cases = [
            makeCase(
                id: "s1", name: "S1", category: .singleEntity,
                frame: makeFrame(units: [
                    makeUnit(id: 1, entityName: "A", predicateName: "kind", value: .string("class")),
                    makeUnit(id: 2, entityName: "A", predicateName: "hasMethod", value: .string("run")),
                ])
            ),
            makeCase(
                id: "s2", name: "S2", category: .multiEntity,
                frame: makeFrame(units: [
                    makeUnit(id: 10, entityName: "B", predicateName: "kind", value: .string("struct")),
                    makeUnit(id: 11, entityName: "C", predicateName: "kind", value: .string("enum")),
                    makeUnit(id: 12, entityName: "D", predicateName: "kind", value: .string("protocol")),
                ])
            ),
        ]

        let report = await runner.run(cases: cases)

        #expect(report.summary.totalCases == 2)
        #expect(report.summary.succeeded == 2)
        #expect(report.summary.averageGroundingCoverage >= 0.0)
        #expect(report.summary.averageClaimCount > 0)
        #expect(report.summary.averageContentLength > 0)
        #expect(!report.summary.completenessDistribution.isEmpty)
        #expect(!report.summary.totalClaimTypeDistribution.isEmpty)
    }

    @Test("Summary handles mixed success and failure")
    func testMixedSummary() async {
        // Use a throwing engine mock to simulate failure
        let failingEngine = FailingReasoningEngine()
        let runner = EvaluationRunner(
            engine: failingEngine,
            engineIdentifier: "com.decode.failing",
            engineVersion: "1.0.0"
        )

        let cases = [
            makeCase(
                id: "fail-1", name: "Failing Case", category: .edgeCase,
                frame: makeFrame(units: [
                    makeUnit(id: 1, entityName: "X", predicateName: "kind", value: .string("class")),
                ])
            ),
        ]

        let report = await runner.run(cases: cases)

        #expect(report.summary.totalCases == 1)
        #expect(report.summary.failed == 1)
        #expect(report.summary.succeeded == 0)
        #expect(report.results[0].error != nil)
    }
}

// MARK: - End-to-End Baseline Tests

@Suite("ExplanationQualityBaseline")
struct ExplanationQualityBaselineTests {

    @Test("Baseline: single entity with kind and method")
    func testBaselineSingleEntity() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units = [
            makeUnit(id: 1, entityName: "SessionManager", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "SessionManager", predicateName: "hasMethod", value: .string("startSession")),
            makeUnit(id: 3, entityName: "SessionManager", predicateName: "hasMethod", value: .string("endSession")),
        ]
        let evalCase = makeCase(
            id: "baseline-single-entity",
            name: "Baseline: Single Entity",
            category: .singleEntity,
            frame: makeFrame(units: units),
            expectations: QualityExpectations(
                minGroundingCoverage: 0.0,
                minClaimCount: 1,
                expectedCompleteness: .partial,
                requireNonEmptyContent: true
            )
        )

        let report = await runner.run(cases: [evalCase], runId: "baseline-v1")
        let result = report.results[0]

        #expect(result.success)
        #expect(result.violations.isEmpty)
        #expect(result.metrics!.totalClaims >= 1)
        #expect(result.metrics!.contentLength > 0)
    }

    @Test("Baseline: multi-entity with diverse types")
    func testBaselineMultiEntity() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units = [
            makeUnit(id: 1, entityName: "UserService", predicateName: "kind", value: .string("struct")),
            makeUnit(id: 2, entityName: "UserService", predicateName: "hasMethod", value: .string("fetchUser")),
            makeUnit(id: 3, entityName: "UserRepository", predicateName: "kind", value: .string("protocol")),
            makeUnit(id: 4, entityName: "UserRepository", predicateName: "hasMethod", value: .string("save")),
            makeUnit(id: 5, entityName: "UserModel", predicateName: "kind", value: .string("struct")),
        ]
        let evalCase = makeCase(
            id: "baseline-multi-entity",
            name: "Baseline: Multi-Entity",
            category: .multiEntity,
            frame: makeFrame(units: units),
            expectations: QualityExpectations(
                minClaimCount: 2,
                expectedCompleteness: .partial,
                requireNonEmptyContent: true
            )
        )

        let report = await runner.run(cases: [evalCase], runId: "baseline-v1")
        let result = report.results[0]

        #expect(result.success)
        #expect(result.violations.isEmpty)
        #expect(result.metrics!.totalClaims >= 2)
    }

    @Test("Baseline: entity with relationships")
    func testBaselineRelationships() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units: [AtomicUnit] = [
            makeUnit(id: 1, entityName: "ViewController", predicateName: "kind", value: .string("class")),
            makeUnit(id: 2, entityName: "ViewController", predicateName: "conformsTo", value: .string("UIViewController")),
            makeRelationshipUnit(id: 3, source: "ViewController", target: "ViewModel", predicate: "calls"),
            makeRelationshipUnit(id: 4, source: "ViewController", target: "Router", predicate: "calls"),
        ]
        let evalCase = makeCase(
            id: "baseline-relationships",
            name: "Baseline: Relationships",
            category: .relationships,
            frame: makeFrame(units: units),
            expectations: QualityExpectations(
                minClaimCount: 1,
                requireNonEmptyContent: true
            )
        )

        let report = await runner.run(cases: [evalCase], runId: "baseline-v1")
        let result = report.results[0]

        #expect(result.success)
        #expect(result.violations.isEmpty)
    }

    @Test("Baseline: T0 and T1 mixed tiers")
    func testBaselineMixedTiers() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let units = [
            makeUnit(id: 1, entityName: "DataStore", predicateName: "kind", value: .string("actor"), tier: .t0),
            makeUnit(id: 2, entityName: "DataStore", predicateName: "purpose", value: .text("Manages persistence"), tier: .t1),
            makeUnit(id: 3, entityName: "DataStore", predicateName: "hasMethod", value: .string("save"), tier: .t0),
            makeUnit(id: 4, entityName: "DataStore", predicateName: "cohesion", value: .string("high"), tier: .t1),
        ]
        let evalCase = makeCase(
            id: "baseline-mixed-tiers",
            name: "Baseline: Mixed Tiers",
            category: .crossFile,
            frame: makeFrame(units: units),
            expectations: QualityExpectations(
                minClaimCount: 1,
                requireNonEmptyContent: true
            )
        )

        let report = await runner.run(cases: [evalCase], runId: "baseline-v1")
        let metrics = report.results[0].metrics!

        #expect(metrics.tierDistribution["t0"] == 2)
        #expect(metrics.tierDistribution["t1"] == 2)
    }

    @Test("Baseline: complete run produces valid JSON")
    func testBaselineJSONExport() async throws {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let cases = [
            makeCase(
                id: "json-1", name: "JSON Test 1", category: .singleEntity,
                frame: makeFrame(units: [
                    makeUnit(id: 1, entityName: "A", predicateName: "kind", value: .string("class")),
                ])
            ),
            makeCase(
                id: "json-2", name: "JSON Test 2", category: .edgeCase,
                frame: makeFrame(units: [])
            ),
        ]

        let report = await runner.run(cases: cases, runId: "json-export-test")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("json-export-test"))
        #expect(json.contains("json-1"))
        #expect(json.contains("json-2"))
        #expect(json.contains("averageGroundingCoverage"))

        // Verify round-trip
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EvaluationReport.self, from: data)
        #expect(decoded.runId == "json-export-test")
        #expect(decoded.results.count == 2)
    }

    @Test("Baseline: regression detection end-to-end")
    func testBaselineRegressionDetection() async {
        let engine = makeDeterministicEngine()
        let runner = EvaluationRunner(
            engine: engine,
            engineIdentifier: ExplainReasoningEngine.identifier,
            engineVersion: ExplainReasoningEngine.version
        )

        let cases = [
            makeCase(
                id: "regression-case", name: "Regression Case", category: .singleEntity,
                frame: makeFrame(units: [
                    makeUnit(id: 1, entityName: "Service", predicateName: "kind", value: .string("class")),
                    makeUnit(id: 2, entityName: "Service", predicateName: "hasMethod", value: .string("execute")),
                ])
            ),
        ]

        // Run baseline
        let baseline = await runner.run(cases: cases, runId: "baseline")

        // Run again (identical — should pass)
        let current = await runner.run(cases: cases, runId: "current")

        let comparator = BaselineComparator()
        let comparison = comparator.compare(baseline: baseline, current: current)

        #expect(comparison.passesBaseline)
        #expect(comparison.regressions.isEmpty)
        #expect(comparison.caseComparisons.count == 1)
    }
}

// MARK: - Failing Engine (for testing error paths)

private struct FailingReasoningEngine: ReasoningEngine, Sendable {
    func reason(
        contextFrame: ContextFrame,
        outputSpecification: OutputSpecification,
        conversationState: ConversationState?
    ) async throws -> ReasoningEngineOutput {
        throw NSError(
            domain: "EvaluationTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Intentional test failure"]
        )
    }
}
