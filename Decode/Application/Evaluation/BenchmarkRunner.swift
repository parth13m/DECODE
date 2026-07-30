// BenchmarkRunner.swift — Decode Application
// E1-01: Benchmark Suite — Pipeline-level benchmark runner.
//
// Exercises the full understanding pipeline for each benchmark case:
// file processing → evidence retrieval → context assembly → consumer invocation.
// Captures per-stage latency, evidence precision/recall, and structural metrics.
// Produces BenchmarkReport with optional baseline comparison.

import Foundation
import DIRCore
import RetrievalRuntime
import ContextAssembly
import ConsumerRuntime
import UpdateEngine

// MARK: - Benchmark Runner

/// Runs benchmark cases through the full understanding pipeline.
///
/// Each benchmark creates a temporary directory, writes source files, processes
/// them through the write pipeline, queries for the target entity, and captures
/// metrics at every stage. Results include evidence precision/recall against
/// structural expectations.
///
/// ## Usage
/// ```swift
/// let runner = BenchmarkRunner(understandingSystem: system, engineVersion: "1.0.0")
/// let report = await runner.run(cases: benchmarkCases)
/// let markdown = BenchmarkReportFormatter.formatMarkdown(report)
/// ```
struct BenchmarkRunner: Sendable {

    private let understandingSystem: UnderstandingSystem
    private let engineVersion: String
    private let contextBudget: Int

    init(
        understandingSystem: UnderstandingSystem,
        engineVersion: String,
        contextBudget: Int = 500
    ) {
        self.understandingSystem = understandingSystem
        self.engineVersion = engineVersion
        self.contextBudget = contextBudget
    }

    /// Runs all benchmark cases and produces a report.
    func run(
        cases: [BenchmarkCase],
        runId: String? = nil,
        baseline: BenchmarkReport? = nil,
        thresholds: BenchmarkThresholds = .default
    ) async -> BenchmarkReport {
        let effectiveRunId = runId ?? UUID().uuidString
        let timestamp = Date()

        var results: [BenchmarkResult] = []
        for benchmarkCase in cases {
            let result = await executeBenchmark(benchmarkCase)
            results.append(result)
        }

        let summary = buildSummary(from: results)

        let comparison: BaselineComparison?
        if let baseline {
            let comparator = BenchmarkComparator(thresholds: thresholds)
            comparison = comparator.compare(baseline: baseline, current: results)
        } else {
            comparison = nil
        }

        return BenchmarkReport(
            runId: effectiveRunId,
            timestamp: timestamp,
            engineVersion: engineVersion,
            results: results,
            summary: summary,
            comparison: comparison
        )
    }

    /// Runs the complete canonical benchmark corpus and produces a report.
    ///
    /// This is the single-command entry point for measuring Decode's intelligence.
    /// Automatically discovers all cases from `BenchmarkCorpus`.
    func runCorpus(
        baseline: BenchmarkReport? = nil,
        thresholds: BenchmarkThresholds = .default,
        categories: Set<BenchmarkCategory>? = nil
    ) async -> BenchmarkReport {
        let cases: [BenchmarkCase]
        if let categories {
            cases = categories.flatMap { BenchmarkCorpus.cases(for: $0) }
        } else {
            cases = BenchmarkCorpus.allCases
        }
        return await run(
            cases: cases,
            baseline: baseline,
            thresholds: thresholds
        )
    }

    // MARK: - Case Execution

    private func executeBenchmark(_ benchmarkCase: BenchmarkCase) async -> BenchmarkResult {
        let timestamp = Date()
        let totalStart = ContinuousClock.now

        // Create temporary directory for source files.
        let tempDir: URL
        do {
            tempDir = try createTempDirectory(for: benchmarkCase.id)
        } catch {
            return makeFailureResult(
                benchmarkCase, timestamp: timestamp,
                error: "Failed to create temp directory: \(error.localizedDescription)",
                failureStage: "setup"
            )
        }
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write source files.
        for file in benchmarkCase.sourceFiles {
            let filePath = tempDir.appendingPathComponent(file.fileName)
            do {
                try file.content.write(to: filePath, atomically: true, encoding: .utf8)
            } catch {
                return makeFailureResult(
                    benchmarkCase, timestamp: timestamp,
                    error: "Failed to write \(file.fileName): \(error.localizedDescription)",
                    failureStage: "setup"
                )
            }
        }

        // Stage 1: Process files through write pipeline.
        let events = benchmarkCase.sourceFiles.map { file in
            UpdateEngine.FileChangeEvent(
                filePath: tempDir.appendingPathComponent(file.fileName).path,
                changeType: .created
            )
        }
        _ = await understandingSystem.processChanges(events)

        // Stage 2: Retrieve evidence.
        // E3-01: Question-aware scope selection — use QuestionClassifier
        // instead of hardcoded purpose→scope mapping.
        let retrievalStart = ContinuousClock.now
        let classification = QuestionClassifier.classify(
            purpose: benchmarkCase.purpose,
            questionHint: benchmarkCase.questionHint
        )
        let entityRef = EntityReference(qualifiedName: benchmarkCase.queryEntity)
        let retrievalRequest = RetrievalRequest(
            subject: .entity(entityRef),
            intent: classification.intent,
            scope: classification.scope,
            budget: contextBudget
        )
        let evidenceSet = await understandingSystem.evidenceRetrieval.retrieve(retrievalRequest)
        let retrievalLatency = ContinuousClock.now - retrievalStart

        if evidenceSet.evidence.isEmpty && benchmarkCase.expectations.requireSuccess {
            return makeFailureResult(
                benchmarkCase, timestamp: timestamp,
                error: "No evidence found for entity '\(benchmarkCase.queryEntity)'",
                failureStage: "retrieval"
            )
        }

        // Stage 3: Assemble context.
        let assemblyStart = ContinuousClock.now
        let contextPurpose = ContextPurpose(benchmarkCase.purpose)
        let assemblyRequest = AssemblyRequest(
            evidenceSet: evidenceSet,
            purpose: contextPurpose,
            budget: contextBudget
        )
        let assemblyResult = await understandingSystem.contextAssembly.assemble(assemblyRequest)
        let assemblyLatency = ContinuousClock.now - assemblyStart

        guard case .success(let contextFrame) = assemblyResult else {
            let reason: String
            if case .rejected(let rejection) = assemblyResult {
                reason = "\(rejection)"
            } else {
                reason = "unknown"
            }
            return makeFailureResult(
                benchmarkCase, timestamp: timestamp,
                error: "Context assembly rejected: \(reason)",
                failureStage: "assembly"
            )
        }

        // Stage 4: Invoke consumer.
        let reasoningStart = ContinuousClock.now
        let consumerRequest = ConsumerRequest(
            contextFrame: contextFrame,
            outputSpecification: OutputSpecification(
                purpose: contextPurpose,
                outputClass: .human,
                detailLevel: .standard
            )
        )
        let consumerResult = await understandingSystem.consumerInvocation.invoke(consumerRequest)
        let reasoningLatency = ContinuousClock.now - reasoningStart

        let totalLatency = ContinuousClock.now - totalStart

        guard case .success(let understanding) = consumerResult else {
            let diagnostic: String
            if case .failure(let failure) = consumerResult {
                diagnostic = failure.diagnostic
            } else {
                diagnostic = "unknown"
            }
            return makeFailureResult(
                benchmarkCase, timestamp: timestamp,
                error: "Consumer failure: \(diagnostic)",
                failureStage: "consumer"
            )
        }

        // Extract metrics.
        let metrics = extractMetrics(
            evidenceSet: evidenceSet,
            contextFrame: contextFrame,
            understanding: understanding,
            expectations: benchmarkCase.expectations,
            retrievalLatency: durationToSeconds(retrievalLatency),
            assemblyLatency: durationToSeconds(assemblyLatency),
            reasoningLatency: durationToSeconds(reasoningLatency),
            totalLatency: durationToSeconds(totalLatency)
        )

        let violations = checkExpectations(
            benchmarkCase.expectations,
            evidenceSet: evidenceSet,
            contextFrame: contextFrame,
            understanding: understanding,
            metrics: metrics
        )

        return BenchmarkResult(
            caseId: benchmarkCase.id,
            caseName: benchmarkCase.name,
            category: benchmarkCase.category.rawValue,
            timestamp: timestamp,
            success: true,
            metrics: metrics,
            violations: violations,
            error: nil,
            failureStage: nil
        )
    }

    // MARK: - Metric Extraction

    private func extractMetrics(
        evidenceSet: EvidenceSet,
        contextFrame: ContextFrame,
        understanding: Understanding,
        expectations: BenchmarkExpectations,
        retrievalLatency: TimeInterval,
        assemblyLatency: TimeInterval,
        reasoningLatency: TimeInterval,
        totalLatency: TimeInterval
    ) -> BenchmarkMetrics {
        let evidenceCount = evidenceSet.evidence.count
        let contextCount = contextFrame.strata.flatMap(\.units).count
        let unusedEvidence = max(0, evidenceCount - contextCount)
        let compressionRatio = evidenceCount > 0
            ? Double(contextCount) / Double(evidenceCount)
            : 0.0

        // Evidence by stage
        var byStage: [String: Int] = [:]
        for unit in evidenceSet.evidence {
            let stage = stageLabel(unit.provenance.stage)
            byStage[stage, default: 0] += 1
        }

        // Evidence by tier
        var byTier: [String: Int] = [:]
        for unit in evidenceSet.evidence {
            byTier[EvaluationRunner.tierLabel(unit.unit.tier), default: 0] += 1
        }

        // Entity recall
        let evidenceEntityNames = extractEntityNames(from: evidenceSet)
        let (foundEntities, missingEntities) = computeRecall(
            expected: expectations.expectedEntities,
            found: evidenceEntityNames
        )
        let entityRecall = expectations.expectedEntities.isEmpty ? 1.0
            : Double(foundEntities.count) / Double(expectations.expectedEntities.count)

        // Relationship recall
        let evidenceRelationships = extractRelationships(from: evidenceSet)
        let (foundRels, missingRels) = computeRelationshipRecall(
            expected: expectations.expectedRelationships,
            found: evidenceRelationships
        )
        let relationshipRecall = expectations.expectedRelationships.isEmpty ? 1.0
            : Double(foundRels.count) / Double(expectations.expectedRelationships.count)

        // Predicate recall — collect all predicates across the entire evidence set
        let entityPredicates = extractPredicates(
            from: evidenceSet,
            forEntity: nil
        )
        let (foundPreds, missingPreds) = computeRecall(
            expected: expectations.expectedPredicates,
            found: entityPredicates
        )
        let predicateRecall = expectations.expectedPredicates.isEmpty ? 1.0
            : Double(foundPreds.count) / Double(expectations.expectedPredicates.count)

        // Stratum distribution
        var stratumDist: [String: Int] = [:]
        for stratum in contextFrame.strata {
            stratumDist[stratum.name] = stratum.units.count
        }

        // Claim type distribution
        var claimTypes: [String: Int] = [:]
        for claim in understanding.claims {
            claimTypes[claim.claimType.rawValue, default: 0] += 1
        }

        return BenchmarkMetrics(
            retrievalLatency: retrievalLatency,
            contextAssemblyLatency: assemblyLatency,
            reasoningLatency: reasoningLatency,
            totalLatency: totalLatency,
            evidenceUnitCount: evidenceCount,
            contextUnitCount: contextCount,
            unusedEvidence: unusedEvidence,
            compressionRatio: compressionRatio,
            evidenceByStage: byStage,
            evidenceByTier: byTier,
            entityRecall: entityRecall,
            foundEntities: foundEntities,
            missingEntities: missingEntities,
            relationshipRecall: relationshipRecall,
            foundRelationships: foundRels,
            missingRelationships: missingRels,
            predicateRecall: predicateRecall,
            foundPredicates: foundPreds,
            missingPredicates: missingPreds,
            groundingCoverage: understanding.metadata.groundingCoverage,
            totalClaims: understanding.claims.count,
            claimTypeDistribution: claimTypes,
            completeness: understanding.metadata.completeness.rawValue,
            degradationLevel: understanding.metadata.degradationLevel.rawValue,
            budgetUtilization: contextFrame.budgetSummary.utilization,
            contentLength: understanding.content.count,
            stratumDistribution: stratumDist,
            engineIdentifier: understanding.metadata.engineIdentifier,
            engineVersion: understanding.metadata.engineVersion
        )
    }

    // MARK: - Evidence Analysis

    private func extractEntityNames(from evidenceSet: EvidenceSet) -> Set<String> {
        var names = Set<String>()
        for unit in evidenceSet.evidence {
            switch unit.unit.subject {
            case .entity(let ref):
                names.insert(ref.qualifiedName)
            case .pair(let pair):
                names.insert(pair.source.qualifiedName)
                names.insert(pair.target.qualifiedName)
            }
        }
        return names
    }

    private func extractRelationships(from evidenceSet: EvidenceSet) -> [(source: String, predicate: String, target: String)] {
        var rels: [(String, String, String)] = []
        for unit in evidenceSet.evidence {
            if case .pair(let pair) = unit.unit.subject {
                rels.append((pair.source.qualifiedName, unit.unit.predicate.name, pair.target.qualifiedName))
            }
        }
        return rels
    }

    private func extractPredicates(from evidenceSet: EvidenceSet, forEntity entityName: String?) -> Set<String> {
        var predicates = Set<String>()
        for unit in evidenceSet.evidence {
            if let entityName {
                if case .entity(let ref) = unit.unit.subject, ref.qualifiedName == entityName {
                    predicates.insert(unit.unit.predicate.name)
                }
            } else {
                predicates.insert(unit.unit.predicate.name)
            }
        }
        return predicates
    }

    private func computeRecall(expected: [String], found: Set<String>) -> (found: [String], missing: [String]) {
        var foundList: [String] = []
        var missingList: [String] = []
        for item in expected {
            if found.contains(item) {
                foundList.append(item)
            } else {
                missingList.append(item)
            }
        }
        return (foundList, missingList)
    }

    private func computeRelationshipRecall(
        expected: [ExpectedRelationship],
        found: [(source: String, predicate: String, target: String)]
    ) -> (found: [String], missing: [String]) {
        var foundList: [String] = []
        var missingList: [String] = []
        for rel in expected {
            let label = "\(rel.source) -[\(rel.predicate)]-> \(rel.target)"
            if found.contains(where: { $0.source == rel.source && $0.predicate == rel.predicate && $0.target == rel.target }) {
                foundList.append(label)
            } else {
                missingList.append(label)
            }
        }
        return (foundList, missingList)
    }

    // MARK: - Expectation Checking

    private func checkExpectations(
        _ expectations: BenchmarkExpectations,
        evidenceSet: EvidenceSet,
        contextFrame: ContextFrame,
        understanding: Understanding,
        metrics: BenchmarkMetrics
    ) -> [ExpectationViolation] {
        var violations: [ExpectationViolation] = []

        if !metrics.missingEntities.isEmpty {
            violations.append(ExpectationViolation(
                expectation: "expectedEntities present in evidence",
                actual: "missing: \(metrics.missingEntities.joined(separator: ", "))",
                description: "Entity recall \(String(format: "%.0f%%", metrics.entityRecall * 100)): \(metrics.missingEntities.count) expected entities not found"
            ))
        }

        if !metrics.missingRelationships.isEmpty {
            violations.append(ExpectationViolation(
                expectation: "expectedRelationships present in evidence",
                actual: "missing: \(metrics.missingRelationships.joined(separator: "; "))",
                description: "Relationship recall \(String(format: "%.0f%%", metrics.relationshipRecall * 100)): \(metrics.missingRelationships.count) expected relationships not found"
            ))
        }

        if !metrics.missingPredicates.isEmpty {
            violations.append(ExpectationViolation(
                expectation: "expectedPredicates present in evidence",
                actual: "missing: \(metrics.missingPredicates.joined(separator: ", "))",
                description: "Predicate recall \(String(format: "%.0f%%", metrics.predicateRecall * 100)): \(metrics.missingPredicates.count) expected predicates not found"
            ))
        }

        if let minCount = expectations.minEvidenceCount, metrics.evidenceUnitCount < minCount {
            violations.append(ExpectationViolation(
                expectation: "evidenceCount >= \(minCount)",
                actual: "\(metrics.evidenceUnitCount)",
                description: "Evidence count \(metrics.evidenceUnitCount) below minimum \(minCount)"
            ))
        }

        if let maxCount = expectations.maxEvidenceCount, metrics.evidenceUnitCount > maxCount {
            violations.append(ExpectationViolation(
                expectation: "evidenceCount <= \(maxCount)",
                actual: "\(metrics.evidenceUnitCount)",
                description: "Evidence count \(metrics.evidenceUnitCount) above maximum \(maxCount) (over-retrieval)"
            ))
        }

        if let minGrounding = expectations.minGroundingCoverage,
           metrics.groundingCoverage < minGrounding {
            violations.append(ExpectationViolation(
                expectation: "groundingCoverage >= \(minGrounding)",
                actual: String(format: "%.2f", metrics.groundingCoverage),
                description: "Grounding coverage \(String(format: "%.2f", metrics.groundingCoverage)) below minimum \(minGrounding)"
            ))
        }

        if let expected = expectations.expectedCompleteness,
           metrics.completeness != expected.rawValue {
            violations.append(ExpectationViolation(
                expectation: "completeness == \(expected.rawValue)",
                actual: metrics.completeness,
                description: "Completeness \(metrics.completeness) does not match expected \(expected.rawValue)"
            ))
        }

        if let expectedStages = expectations.expectedStages {
            let presentStages = Set(metrics.evidenceByStage.filter { $0.value > 0 }.keys)
            let missingStages = expectedStages.subtracting(presentStages)
            if !missingStages.isEmpty {
                violations.append(ExpectationViolation(
                    expectation: "expectedStages present: \(expectedStages.sorted().joined(separator: ", "))",
                    actual: "present: \(presentStages.sorted().joined(separator: ", "))",
                    description: "Missing evidence stages: \(missingStages.sorted().joined(separator: ", "))"
                ))
            }
        }

        if let expectedTiers = expectations.expectedTiers {
            let presentTiers = Set(metrics.evidenceByTier.filter { $0.value > 0 }.keys)
            let missingTiers = expectedTiers.subtracting(presentTiers)
            if !missingTiers.isEmpty {
                violations.append(ExpectationViolation(
                    expectation: "expectedTiers present: \(expectedTiers.sorted().joined(separator: ", "))",
                    actual: "present: \(presentTiers.sorted().joined(separator: ", "))",
                    description: "Missing evidence tiers: \(missingTiers.sorted().joined(separator: ", "))"
                ))
            }
        }

        return violations
    }

    // MARK: - Summary

    private func buildSummary(from results: [BenchmarkResult]) -> BenchmarkSummary {
        let successful = results.filter { $0.success }
        let metrics = successful.compactMap(\.metrics)

        let avg = { (values: [Double]) -> Double in
            values.isEmpty ? 0.0 : values.reduce(0, +) / Double(values.count)
        }

        var completenessDist: [String: Int] = [:]
        for m in metrics { completenessDist[m.completeness, default: 0] += 1 }

        let expectationsMet = results.filter { $0.violations.isEmpty && $0.success }.count
        let expectationsViolated = results.filter { !$0.violations.isEmpty }.count

        // Category scores
        var categoryScores: [String: CategoryScore] = [:]
        let byCategory = Dictionary(grouping: results, by: \.category)
        for (category, categoryResults) in byCategory {
            let catSuccessful = categoryResults.filter { $0.success }
            let catMetrics = catSuccessful.compactMap(\.metrics)
            let catExpMet = categoryResults.filter { $0.violations.isEmpty && $0.success }.count
            categoryScores[category] = CategoryScore(
                caseCount: categoryResults.count,
                succeeded: catSuccessful.count,
                expectationsMet: catExpMet,
                averageEntityRecall: catMetrics.isEmpty ? 0 : avg(catMetrics.map(\.entityRecall)),
                averageRelationshipRecall: catMetrics.isEmpty ? 0 : avg(catMetrics.map(\.relationshipRecall)),
                averageGroundingCoverage: catMetrics.isEmpty ? 0 : avg(catMetrics.map(\.groundingCoverage))
            )
        }

        return BenchmarkSummary(
            totalCases: results.count,
            succeeded: successful.count,
            failed: results.count - successful.count,
            expectationsMet: expectationsMet,
            expectationsViolated: expectationsViolated,
            averageEntityRecall: avg(metrics.map(\.entityRecall)),
            averageRelationshipRecall: avg(metrics.map(\.relationshipRecall)),
            averagePredicateRecall: avg(metrics.map(\.predicateRecall)),
            averageGroundingCoverage: avg(metrics.map(\.groundingCoverage)),
            averageEvidenceCount: avg(metrics.map { Double($0.evidenceUnitCount) }),
            averageContextUnitCount: avg(metrics.map { Double($0.contextUnitCount) }),
            averageCompressionRatio: avg(metrics.map(\.compressionRatio)),
            averageRetrievalLatency: avg(metrics.map(\.retrievalLatency)),
            averageAssemblyLatency: avg(metrics.map(\.contextAssemblyLatency)),
            averageReasoningLatency: avg(metrics.map(\.reasoningLatency)),
            averageTotalLatency: avg(metrics.map(\.totalLatency)),
            averageBudgetUtilization: avg(metrics.map(\.budgetUtilization)),
            averageContentLength: avg(metrics.map { Double($0.contentLength) }),
            completenessDistribution: completenessDist,
            totalMissingEntities: metrics.reduce(0) { $0 + $1.missingEntities.count },
            totalMissingRelationships: metrics.reduce(0) { $0 + $1.missingRelationships.count },
            categoryScores: categoryScores
        )
    }

    // MARK: - Helpers

    private func createTempDirectory(for caseId: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DecodeBenchmark-\(caseId)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFailureResult(
        _ benchmarkCase: BenchmarkCase,
        timestamp: Date,
        error: String,
        failureStage: String
    ) -> BenchmarkResult {
        BenchmarkResult(
            caseId: benchmarkCase.id,
            caseName: benchmarkCase.name,
            category: benchmarkCase.category.rawValue,
            timestamp: timestamp,
            success: false,
            metrics: nil,
            violations: [],
            error: error,
            failureStage: failureStage
        )
    }

    private func stageLabel(_ stage: EvidenceStage) -> String {
        switch stage {
        case .direct: return "direct"
        case .relational: return "relational"
        case .scope: return "scope"
        }
    }

    private func durationToSeconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1_000_000_000_000_000_000
    }
}

// MARK: - Benchmark Comparator

/// Compares benchmark results against a baseline to detect regressions.
struct BenchmarkComparator: Sendable {

    let thresholds: BenchmarkThresholds

    init(thresholds: BenchmarkThresholds = .default) {
        self.thresholds = thresholds
    }

    func compare(
        baseline: BenchmarkReport,
        current: [BenchmarkResult]
    ) -> BaselineComparison {
        let baselineById = Dictionary(
            baseline.results.map { ($0.caseId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var allRegressions: [MetricRegression] = []
        var allImprovements: [MetricImprovement] = []
        var caseComparisons: [CaseComparison] = []

        for result in current {
            let baselineResult = baselineById[result.caseId]
            let comparison = compareCase(baseline: baselineResult, current: result)
            caseComparisons.append(comparison)
            allRegressions.append(contentsOf: comparison.regressions)
            allImprovements.append(contentsOf: comparison.improvements)
        }

        return BaselineComparison(
            baselineRunId: baseline.runId,
            currentRunId: "current",
            timestamp: Date(),
            caseComparisons: caseComparisons,
            regressions: allRegressions,
            improvements: allImprovements,
            passesBaseline: allRegressions.isEmpty
        )
    }

    private func compareCase(
        baseline: BenchmarkResult?,
        current: BenchmarkResult
    ) -> CaseComparison {
        guard let baselineMetrics = baseline?.metrics,
              let currentMetrics = current.metrics else {
            return CaseComparison(
                caseId: current.caseId,
                caseName: current.caseName,
                baselineMetrics: nil,
                currentMetrics: nil,
                regressions: [],
                improvements: []
            )
        }

        // Convert BenchmarkMetrics to EvaluationMetrics for CaseComparison
        let baseEval = toEvaluationMetrics(baselineMetrics)
        let currEval = toEvaluationMetrics(currentMetrics)

        var regressions: [MetricRegression] = []
        var improvements: [MetricImprovement] = []

        check("entityRecall", baseline: baselineMetrics.entityRecall, current: currentMetrics.entityRecall, threshold: thresholds.entityRecallThreshold, higherIsBetter: true, regressions: &regressions, improvements: &improvements)
        check("relationshipRecall", baseline: baselineMetrics.relationshipRecall, current: currentMetrics.relationshipRecall, threshold: thresholds.relationshipRecallThreshold, higherIsBetter: true, regressions: &regressions, improvements: &improvements)
        check("predicateRecall", baseline: baselineMetrics.predicateRecall, current: currentMetrics.predicateRecall, threshold: thresholds.predicateRecallThreshold, higherIsBetter: true, regressions: &regressions, improvements: &improvements)
        check("groundingCoverage", baseline: baselineMetrics.groundingCoverage, current: currentMetrics.groundingCoverage, threshold: thresholds.groundingCoverageThreshold, higherIsBetter: true, regressions: &regressions, improvements: &improvements)
        check("budgetUtilization", baseline: baselineMetrics.budgetUtilization, current: currentMetrics.budgetUtilization, threshold: thresholds.budgetUtilizationThreshold, higherIsBetter: true, regressions: &regressions, improvements: &improvements)
        check("compressionRatio", baseline: baselineMetrics.compressionRatio, current: currentMetrics.compressionRatio, threshold: thresholds.compressionThreshold, higherIsBetter: true, regressions: &regressions, improvements: &improvements)

        if baselineMetrics.totalLatency > 0 {
            check("totalLatency", baseline: baselineMetrics.totalLatency, current: currentMetrics.totalLatency, threshold: thresholds.latencyThreshold * baselineMetrics.totalLatency, higherIsBetter: false, regressions: &regressions, improvements: &improvements)
        }

        return CaseComparison(
            caseId: current.caseId,
            caseName: current.caseName,
            baselineMetrics: baseEval,
            currentMetrics: currEval,
            regressions: regressions,
            improvements: improvements
        )
    }

    private func check(
        _ name: String,
        baseline: Double,
        current: Double,
        threshold: Double,
        higherIsBetter: Bool,
        regressions: inout [MetricRegression],
        improvements: inout [MetricImprovement]
    ) {
        let delta = current - baseline
        if higherIsBetter {
            if delta < -threshold {
                regressions.append(MetricRegression(metric: name, baselineValue: baseline, currentValue: current, delta: delta, threshold: threshold))
            } else if delta > threshold {
                improvements.append(MetricImprovement(metric: name, baselineValue: baseline, currentValue: current, delta: delta))
            }
        } else {
            if delta > threshold {
                regressions.append(MetricRegression(metric: name, baselineValue: baseline, currentValue: current, delta: delta, threshold: threshold))
            } else if delta < -threshold {
                improvements.append(MetricImprovement(metric: name, baselineValue: baseline, currentValue: current, delta: delta))
            }
        }
    }

    private func toEvaluationMetrics(_ bm: BenchmarkMetrics) -> EvaluationMetrics {
        EvaluationMetrics(
            groundingCoverage: bm.groundingCoverage,
            totalClaims: bm.totalClaims,
            groundedClaims: bm.totalClaims, // Claim-level grounding not tracked in benchmarks
            claimTypeDistribution: bm.claimTypeDistribution,
            evidenceSetSize: bm.evidenceUnitCount,
            selectedCount: bm.contextUnitCount,
            elisionRatio: bm.evidenceUnitCount > 0 ? 1.0 - bm.compressionRatio : 0.0,
            tierDistribution: bm.evidenceByTier,
            stratumDistribution: bm.stratumDistribution,
            degradationLevel: bm.degradationLevel,
            budgetUtilization: bm.budgetUtilization,
            budgetTotal: bm.contextUnitCount > 0 ? Int(Double(bm.contextUnitCount) / max(bm.budgetUtilization, 0.001)) : 0,
            budgetUsed: bm.contextUnitCount,
            completeness: bm.completeness,
            contentLength: bm.contentLength,
            entityCount: bm.foundEntities.count,
            engineIdentifier: bm.engineIdentifier,
            engineVersion: bm.engineVersion,
            isStale: false
        )
    }
}

// MARK: - Report Formatter

/// Formats benchmark reports as human-readable Markdown.
enum BenchmarkReportFormatter {

    static func formatMarkdown(_ report: BenchmarkReport) -> String {
        var md = "# Benchmark Report\n\n"
        md += "- **Run ID:** \(report.runId)\n"
        md += "- **Timestamp:** \(iso8601(report.timestamp))\n"
        md += "- **Engine Version:** \(report.engineVersion)\n\n"

        // Summary
        md += "## Summary\n\n"
        let s = report.summary
        md += "| Metric | Value |\n|--------|-------|\n"
        md += "| Total cases | \(s.totalCases) |\n"
        md += "| Succeeded | \(s.succeeded) |\n"
        md += "| Failed | \(s.failed) |\n"
        md += "| Expectations met | \(s.expectationsMet) |\n"
        md += "| Expectations violated | \(s.expectationsViolated) |\n"
        md += "| Avg entity recall | \(pct(s.averageEntityRecall)) |\n"
        md += "| Avg relationship recall | \(pct(s.averageRelationshipRecall)) |\n"
        md += "| Avg predicate recall | \(pct(s.averagePredicateRecall)) |\n"
        md += "| Avg grounding coverage | \(pct(s.averageGroundingCoverage)) |\n"
        md += "| Avg evidence count | \(String(format: "%.1f", s.averageEvidenceCount)) |\n"
        md += "| Avg context units | \(String(format: "%.1f", s.averageContextUnitCount)) |\n"
        md += "| Avg compression ratio | \(pct(s.averageCompressionRatio)) |\n"
        md += "| Avg retrieval latency | \(ms(s.averageRetrievalLatency)) |\n"
        md += "| Avg assembly latency | \(ms(s.averageAssemblyLatency)) |\n"
        md += "| Avg reasoning latency | \(ms(s.averageReasoningLatency)) |\n"
        md += "| Avg total latency | \(ms(s.averageTotalLatency)) |\n"
        md += "| Avg budget utilization | \(pct(s.averageBudgetUtilization)) |\n"
        md += "| Total missing entities | \(s.totalMissingEntities) |\n"
        md += "| Total missing relationships | \(s.totalMissingRelationships) |\n\n"

        // Category Scores
        if !s.categoryScores.isEmpty {
            md += "## Category Scores\n\n"
            md += "| Category | Cases | Pass | Entity Recall | Rel Recall | Grounding | Score |\n"
            md += "|----------|-------|------|---------------|------------|-----------|-------|\n"
            for category in s.categoryScores.keys.sorted() {
                let cs = s.categoryScores[category]!
                md += "| \(category) | \(cs.caseCount) | \(cs.expectationsMet)/\(cs.caseCount)"
                md += " | \(pct(cs.averageEntityRecall)) | \(pct(cs.averageRelationshipRecall))"
                md += " | \(pct(cs.averageGroundingCoverage)) | \(pct(cs.compositeScore)) |\n"
            }

            // Total score
            let allScores = s.categoryScores.values
            let totalComposite = allScores.isEmpty ? 0.0
                : allScores.map(\.compositeScore).reduce(0, +) / Double(allScores.count)
            md += "\n**Total Score: \(pct(totalComposite))**\n\n"
        }

        // Comparison
        if let comparison = report.comparison {
            md += "## Baseline Comparison\n\n"
            md += "Baseline: \(comparison.baselineRunId)\n\n"

            if comparison.passesBaseline {
                md += "**PASS** — No regressions detected.\n\n"
            } else {
                md += "**FAIL** — \(comparison.regressions.count) regression(s) detected.\n\n"
            }

            if !comparison.regressions.isEmpty {
                md += "### Regressions\n\n"
                md += "| Metric | Baseline | Current | Delta | Threshold |\n"
                md += "|--------|----------|---------|-------|-----------|\n"
                for r in comparison.regressions {
                    md += "| \(r.metric) | \(fmt(r.baselineValue)) | \(fmt(r.currentValue)) | \(fmt(r.delta)) | \(fmt(r.threshold)) |\n"
                }
                md += "\n"
            }

            if !comparison.improvements.isEmpty {
                md += "### Improvements\n\n"
                md += "| Metric | Baseline | Current | Delta |\n"
                md += "|--------|----------|---------|-------|\n"
                for i in comparison.improvements {
                    md += "| \(i.metric) | \(fmt(i.baselineValue)) | \(fmt(i.currentValue)) | \(fmt(i.delta)) |\n"
                }
                md += "\n"
            }
        }

        // Per-case results
        md += "## Results by Case\n\n"
        for result in report.results {
            md += "### \(result.caseName)\n\n"
            md += "- **ID:** \(result.caseId)\n"
            md += "- **Category:** \(result.category)\n"
            md += "- **Status:** \(result.success ? "PASS" : "FAIL")\n"

            if let error = result.error {
                md += "- **Error:** \(error)\n"
                if let stage = result.failureStage {
                    md += "- **Failed at:** \(stage)\n"
                }
            }

            if let m = result.metrics {
                md += "\n| Metric | Value |\n|--------|-------|\n"
                md += "| Evidence units | \(m.evidenceUnitCount) |\n"
                md += "| Context units | \(m.contextUnitCount) |\n"
                md += "| Unused evidence | \(m.unusedEvidence) |\n"
                md += "| Compression ratio | \(pct(m.compressionRatio)) |\n"
                md += "| Entity recall | \(pct(m.entityRecall)) |\n"
                md += "| Relationship recall | \(pct(m.relationshipRecall)) |\n"
                md += "| Predicate recall | \(pct(m.predicateRecall)) |\n"
                md += "| Grounding coverage | \(pct(m.groundingCoverage)) |\n"
                md += "| Total claims | \(m.totalClaims) |\n"
                md += "| Completeness | \(m.completeness) |\n"
                md += "| Budget utilization | \(pct(m.budgetUtilization)) |\n"
                md += "| Content length | \(m.contentLength) |\n"
                md += "| Retrieval latency | \(ms(m.retrievalLatency)) |\n"
                md += "| Assembly latency | \(ms(m.contextAssemblyLatency)) |\n"
                md += "| Reasoning latency | \(ms(m.reasoningLatency)) |\n"
                md += "| Total latency | \(ms(m.totalLatency)) |\n"

                if !m.missingEntities.isEmpty {
                    md += "\n**Missing entities:** \(m.missingEntities.joined(separator: ", "))\n"
                }
                if !m.missingRelationships.isEmpty {
                    md += "\n**Missing relationships:** \(m.missingRelationships.joined(separator: "; "))\n"
                }
            }

            if !result.violations.isEmpty {
                md += "\n**Violations:**\n"
                for v in result.violations {
                    md += "- \(v.description)\n"
                }
            }

            md += "\n---\n\n"
        }

        return md
    }

    // MARK: - Formatting Helpers

    private static func pct(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func ms(_ value: TimeInterval) -> String {
        String(format: "%.1fms", value * 1000)
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
