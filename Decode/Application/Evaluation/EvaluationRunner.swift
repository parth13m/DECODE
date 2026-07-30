// EvaluationRunner.swift — Decode Application
// E1-01: Explanation Quality Baseline — Benchmark runner.
//
// Orchestrates evaluation cases through reasoning engines, captures metrics
// from pipeline outputs, and produces structured reports. Designed for
// deterministic, repeatable execution without AI provider dependencies.

import Foundation
import ConsumerRuntime
import ContextAssembly
import DIRCore

// MARK: - Evaluation Runner

/// Runs evaluation cases through reasoning engines and produces structured reports.
///
/// The runner is stateless — each `run()` invocation is independent. Results
/// are returned as an `EvaluationReport` that can be serialized to JSON for
/// storage, CI comparison, or historical analysis.
///
/// ## Usage
/// ```swift
/// let runner = EvaluationRunner(engine: explainEngine, engineId: "com.decode.explain", engineVersion: "1.0.0")
/// let report = await runner.run(cases: evaluationCases)
/// let json = try JSONEncoder().encode(report)
/// ```
struct EvaluationRunner: Sendable {

    private let engine: ReasoningEngine
    private let engineIdentifier: String
    private let engineVersion: String

    init(engine: ReasoningEngine, engineIdentifier: String, engineVersion: String) {
        self.engine = engine
        self.engineIdentifier = engineIdentifier
        self.engineVersion = engineVersion
    }

    /// Runs all evaluation cases and produces a report.
    func run(cases: [EvaluationCase], runId: String? = nil) async -> EvaluationReport {
        let effectiveRunId = runId ?? UUID().uuidString
        let timestamp = Date()

        var results: [EvaluationResult] = []
        for evalCase in cases {
            let result = await evaluate(evalCase)
            results.append(result)
        }

        let summary = buildSummary(from: results)

        return EvaluationReport(
            runId: effectiveRunId,
            timestamp: timestamp,
            engineVersion: engineVersion,
            results: results,
            summary: summary
        )
    }

    // MARK: - Case Evaluation

    /// Evaluates a single case by invoking the reasoning engine.
    private func evaluate(_ evalCase: EvaluationCase) async -> EvaluationResult {
        let timestamp = Date()

        do {
            let output = try await engine.reason(
                contextFrame: evalCase.contextFrame,
                outputSpecification: evalCase.outputSpecification,
                conversationState: nil
            )

            let metrics = extractMetrics(
                from: output,
                contextFrame: evalCase.contextFrame
            )

            let violations = checkExpectations(
                metrics: metrics,
                content: output.content,
                expectations: evalCase.expectations
            )

            return EvaluationResult(
                caseId: evalCase.id,
                caseName: evalCase.name,
                category: evalCase.category.rawValue,
                timestamp: timestamp,
                metrics: metrics,
                success: true,
                error: nil,
                violations: violations
            )
        } catch {
            return EvaluationResult(
                caseId: evalCase.id,
                caseName: evalCase.name,
                category: evalCase.category.rawValue,
                timestamp: timestamp,
                metrics: nil,
                success: false,
                error: error.localizedDescription,
                violations: []
            )
        }
    }

    // MARK: - Metric Extraction

    /// Extracts structured metrics from engine output and context frame.
    private func extractMetrics(
        from output: ReasoningEngineOutput,
        contextFrame: ContextFrame
    ) -> EvaluationMetrics {
        let allUnits = contextFrame.strata.flatMap { $0.units }
        let allUnitIds = Set(allUnits.map { $0.annotatedUnit.unit.id })

        // Grounding metrics
        let groundedClaims = output.claims.filter { !$0.groundingReferences.isEmpty }
        let referencedUnitIds = Set(output.claims.flatMap { $0.groundingReferences })
        let groundingCoverage = allUnitIds.isEmpty ? 0.0
            : Double(referencedUnitIds.intersection(allUnitIds).count) / Double(allUnitIds.count)

        // Claim type distribution
        var claimTypeDist: [String: Int] = [:]
        for claim in output.claims {
            claimTypeDist[claim.claimType.rawValue, default: 0] += 1
        }

        // Tier distribution from context frame metadata
        var tierDist: [String: Int] = [:]
        for (tier, count) in contextFrame.metadata.tierCounts {
            tierDist[Self.tierLabel(tier)] = count
        }

        // Stratum distribution
        var stratumDist: [String: Int] = [:]
        for stratum in contextFrame.strata {
            stratumDist[stratum.name] = stratum.units.count
        }

        // Entity count from claims
        let entityNames = Set(output.claims.compactMap { claim -> String? in
            // Extract entity names from claim content — claims reference entities by name
            for unit in allUnits {
                if case .entity(let ref) = unit.annotatedUnit.unit.subject {
                    if claim.content.contains(ref.qualifiedName) {
                        return ref.qualifiedName
                    }
                }
            }
            return nil
        })

        return EvaluationMetrics(
            groundingCoverage: groundingCoverage,
            totalClaims: output.claims.count,
            groundedClaims: groundedClaims.count,
            claimTypeDistribution: claimTypeDist,
            evidenceSetSize: contextFrame.metadata.evidenceSetSize,
            selectedCount: contextFrame.metadata.selectedCount,
            elisionRatio: contextFrame.metadata.elisionRatio,
            tierDistribution: tierDist,
            stratumDistribution: stratumDist,
            degradationLevel: contextFrame.metadata.degradationLevel.rawValue,
            budgetUtilization: contextFrame.budgetSummary.utilization,
            budgetTotal: contextFrame.budgetSummary.total,
            budgetUsed: contextFrame.budgetSummary.used,
            completeness: output.completeness.rawValue,
            contentLength: output.content.count,
            entityCount: entityNames.count,
            engineIdentifier: engineIdentifier,
            engineVersion: engineVersion,
            isStale: contextFrame.metadata.freshnessState != .fresh
        )
    }

    // MARK: - Expectation Checking

    /// Checks metrics against quality expectations and returns violations.
    private func checkExpectations(
        metrics: EvaluationMetrics,
        content: String,
        expectations: QualityExpectations?
    ) -> [ExpectationViolation] {
        guard let expectations else { return [] }

        var violations: [ExpectationViolation] = []

        if let minGrounding = expectations.minGroundingCoverage,
           metrics.groundingCoverage < minGrounding {
            violations.append(ExpectationViolation(
                expectation: "groundingCoverage >= \(minGrounding)",
                actual: "\(metrics.groundingCoverage)",
                description: "Grounding coverage \(String(format: "%.2f", metrics.groundingCoverage)) below minimum \(minGrounding)"
            ))
        }

        if let minClaims = expectations.minClaimCount,
           metrics.totalClaims < minClaims {
            violations.append(ExpectationViolation(
                expectation: "totalClaims >= \(minClaims)",
                actual: "\(metrics.totalClaims)",
                description: "Claim count \(metrics.totalClaims) below minimum \(minClaims)"
            ))
        }

        if let expectedCompleteness = expectations.expectedCompleteness,
           metrics.completeness != expectedCompleteness.rawValue {
            violations.append(ExpectationViolation(
                expectation: "completeness == \(expectedCompleteness.rawValue)",
                actual: metrics.completeness,
                description: "Completeness \(metrics.completeness) does not match expected \(expectedCompleteness.rawValue)"
            ))
        }

        if expectations.requireNonEmptyContent && content.isEmpty {
            violations.append(ExpectationViolation(
                expectation: "content is non-empty",
                actual: "empty",
                description: "Output content is empty"
            ))
        }

        return violations
    }

    // MARK: - Summary Construction

    /// Builds an aggregated summary from individual results.
    private func buildSummary(from results: [EvaluationResult]) -> EvaluationSummary {
        let successful = results.filter { $0.success }
        let successMetrics = successful.compactMap(\.metrics)

        let totalClaims = successMetrics.reduce(0) { $0 + $1.totalClaims }
        let avgGrounding = successMetrics.isEmpty ? 0.0
            : successMetrics.reduce(0.0) { $0 + $1.groundingCoverage } / Double(successMetrics.count)
        let avgClaims = successMetrics.isEmpty ? 0.0
            : Double(totalClaims) / Double(successMetrics.count)
        let avgContentLength = successMetrics.isEmpty ? 0.0
            : Double(successMetrics.reduce(0) { $0 + $1.contentLength }) / Double(successMetrics.count)
        let avgBudget = successMetrics.isEmpty ? 0.0
            : successMetrics.reduce(0.0) { $0 + $1.budgetUtilization } / Double(successMetrics.count)

        // Completeness distribution
        var completenessDist: [String: Int] = [:]
        for m in successMetrics {
            completenessDist[m.completeness, default: 0] += 1
        }

        // Total claim type distribution
        var totalClaimTypes: [String: Int] = [:]
        for m in successMetrics {
            for (type, count) in m.claimTypeDistribution {
                totalClaimTypes[type, default: 0] += count
            }
        }

        // Average tier distribution
        var tierTotals: [String: Double] = [:]
        for m in successMetrics {
            for (tier, count) in m.tierDistribution {
                tierTotals[tier, default: 0] += Double(count)
            }
        }
        let avgTierDist = successMetrics.isEmpty ? tierTotals
            : tierTotals.mapValues { $0 / Double(successMetrics.count) }

        let expectationsMet = results.filter { $0.violations.isEmpty && $0.success }.count
        let expectationsViolated = results.filter { !$0.violations.isEmpty }.count

        return EvaluationSummary(
            totalCases: results.count,
            succeeded: successful.count,
            failed: results.count - successful.count,
            expectationsMet: expectationsMet,
            expectationsViolated: expectationsViolated,
            averageGroundingCoverage: avgGrounding,
            averageClaimCount: avgClaims,
            averageContentLength: avgContentLength,
            averageBudgetUtilization: avgBudget,
            completenessDistribution: completenessDist,
            totalClaimTypeDistribution: totalClaimTypes,
            averageTierDistribution: avgTierDist
        )
    }
}

// MARK: - Baseline Comparator

/// Compares two evaluation reports to detect regressions and improvements.
struct BaselineComparator: Sendable {

    let thresholds: ComparisonThresholds

    init(thresholds: ComparisonThresholds = .default) {
        self.thresholds = thresholds
    }

    /// Compares a current report against a baseline report.
    func compare(
        baseline: EvaluationReport,
        current: EvaluationReport
    ) -> BaselineComparison {
        var caseComparisons: [CaseComparison] = []
        var allRegressions: [MetricRegression] = []
        var allImprovements: [MetricImprovement] = []

        // Match cases by ID
        let baselineById = Dictionary(
            baseline.results.map { ($0.caseId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for currentResult in current.results {
            let baselineResult = baselineById[currentResult.caseId]
            let comparison = compareCaseMetrics(
                caseId: currentResult.caseId,
                caseName: currentResult.caseName,
                baseline: baselineResult?.metrics,
                current: currentResult.metrics
            )
            caseComparisons.append(comparison)
            allRegressions.append(contentsOf: comparison.regressions)
            allImprovements.append(contentsOf: comparison.improvements)
        }

        // Summary-level comparison
        let summaryRegressions = compareSummaryMetrics(
            baseline: baseline.summary,
            current: current.summary
        )
        allRegressions.append(contentsOf: summaryRegressions.regressions)
        allImprovements.append(contentsOf: summaryRegressions.improvements)

        return BaselineComparison(
            baselineRunId: baseline.runId,
            currentRunId: current.runId,
            timestamp: Date(),
            caseComparisons: caseComparisons,
            regressions: allRegressions,
            improvements: allImprovements,
            passesBaseline: allRegressions.isEmpty
        )
    }

    // MARK: - Case-Level Comparison

    private func compareCaseMetrics(
        caseId: String,
        caseName: String,
        baseline: EvaluationMetrics?,
        current: EvaluationMetrics?
    ) -> CaseComparison {
        guard let baseline, let current else {
            return CaseComparison(
                caseId: caseId,
                caseName: caseName,
                baselineMetrics: baseline,
                currentMetrics: current,
                regressions: [],
                improvements: []
            )
        }

        var regressions: [MetricRegression] = []
        var improvements: [MetricImprovement] = []

        // Grounding coverage: higher is better
        checkMetric(
            name: "groundingCoverage",
            baseline: baseline.groundingCoverage,
            current: current.groundingCoverage,
            threshold: thresholds.groundingCoverageThreshold,
            higherIsBetter: true,
            regressions: &regressions,
            improvements: &improvements
        )

        // Claim count: higher is better
        if baseline.totalClaims > 0 {
            let baselineClaims = Double(baseline.totalClaims)
            let currentClaims = Double(current.totalClaims)
            checkMetric(
                name: "totalClaims",
                baseline: baselineClaims,
                current: currentClaims,
                threshold: thresholds.claimCountThreshold * baselineClaims,
                higherIsBetter: true,
                regressions: &regressions,
                improvements: &improvements
            )
        }

        // Content length: higher is better (more informative)
        if baseline.contentLength > 0 {
            let baselineLen = Double(baseline.contentLength)
            let currentLen = Double(current.contentLength)
            checkMetric(
                name: "contentLength",
                baseline: baselineLen,
                current: currentLen,
                threshold: thresholds.contentLengthThreshold * baselineLen,
                higherIsBetter: true,
                regressions: &regressions,
                improvements: &improvements
            )
        }

        // Budget utilization: higher is better (using available evidence)
        checkMetric(
            name: "budgetUtilization",
            baseline: baseline.budgetUtilization,
            current: current.budgetUtilization,
            threshold: thresholds.budgetUtilizationThreshold,
            higherIsBetter: true,
            regressions: &regressions,
            improvements: &improvements
        )

        return CaseComparison(
            caseId: caseId,
            caseName: caseName,
            baselineMetrics: baseline,
            currentMetrics: current,
            regressions: regressions,
            improvements: improvements
        )
    }

    // MARK: - Summary-Level Comparison

    private func compareSummaryMetrics(
        baseline: EvaluationSummary,
        current: EvaluationSummary
    ) -> (regressions: [MetricRegression], improvements: [MetricImprovement]) {
        var regressions: [MetricRegression] = []
        var improvements: [MetricImprovement] = []

        checkMetric(
            name: "summary.averageGroundingCoverage",
            baseline: baseline.averageGroundingCoverage,
            current: current.averageGroundingCoverage,
            threshold: thresholds.groundingCoverageThreshold,
            higherIsBetter: true,
            regressions: &regressions,
            improvements: &improvements
        )

        checkMetric(
            name: "summary.averageClaimCount",
            baseline: baseline.averageClaimCount,
            current: current.averageClaimCount,
            threshold: thresholds.claimCountThreshold * baseline.averageClaimCount,
            higherIsBetter: true,
            regressions: &regressions,
            improvements: &improvements
        )

        return (regressions, improvements)
    }

    // MARK: - Metric Comparison Helper

    private func checkMetric(
        name: String,
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
                regressions.append(MetricRegression(
                    metric: name,
                    baselineValue: baseline,
                    currentValue: current,
                    delta: delta,
                    threshold: threshold
                ))
            } else if delta > threshold {
                improvements.append(MetricImprovement(
                    metric: name,
                    baselineValue: baseline,
                    currentValue: current,
                    delta: delta
                ))
            }
        } else {
            if delta > threshold {
                regressions.append(MetricRegression(
                    metric: name,
                    baselineValue: baseline,
                    currentValue: current,
                    delta: delta,
                    threshold: threshold
                ))
            } else if delta < -threshold {
                improvements.append(MetricImprovement(
                    metric: name,
                    baselineValue: baseline,
                    currentValue: current,
                    delta: delta
                ))
            }
        }
    }
}

// MARK: - Tier Label Helper

extension EvaluationRunner {
    /// Stable string label for a Tier value (used in Codable metric dictionaries).
    static func tierLabel(_ tier: Tier) -> String {
        switch tier {
        case .t0: return "t0"
        case .t1: return "t1"
        case .t2: return "t2"
        }
    }
}
