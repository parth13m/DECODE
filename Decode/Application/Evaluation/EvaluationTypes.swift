// EvaluationTypes.swift — Decode Application
// E1-01: Explanation Quality Baseline — Evaluation framework types.
//
// Structured, Codable types for capturing explanation quality metrics,
// evaluation results, and baseline comparisons. All metrics are derived
// from existing pipeline types (Understanding, ContextFrame, UnderstandingClaim).

import Foundation
import ConsumerRuntime
import ContextAssembly
import DIRCore

// MARK: - Evaluation Case

/// A named, reproducible evaluation scenario.
///
/// Each case defines an input (context frame + output specification) and optional
/// quality expectations. Cases are constructed programmatically — the context frame
/// types are not Codable by design (they reference pipeline-internal types).
struct EvaluationCase: Sendable {
    /// Stable identifier for this case (e.g., "single-entity-class").
    let id: String

    /// Human-readable name.
    let name: String

    /// What this case tests.
    let description: String

    /// Classification for grouping results.
    let category: EvaluationCategory

    /// The context frame to evaluate against.
    let contextFrame: ContextFrame

    /// The output specification for the reasoning engine.
    let outputSpecification: OutputSpecification

    /// Optional quality expectations for regression detection.
    let expectations: QualityExpectations?
}

/// Categories for organizing evaluation cases.
enum EvaluationCategory: String, Codable, Sendable, CaseIterable {
    case singleEntity
    case multiEntity
    case relationships
    case crossFile
    case moduleContext
    case edgeCase
}

/// Quality expectations for an evaluation case.
///
/// Each field is optional — only specified expectations are checked.
struct QualityExpectations: Sendable {
    /// Minimum grounding coverage (0.0–1.0).
    let minGroundingCoverage: Double?

    /// Minimum number of claims.
    let minClaimCount: Int?

    /// Expected completeness level.
    let expectedCompleteness: CompletenessAssessment?

    /// Whether content must be non-empty.
    let requireNonEmptyContent: Bool

    init(
        minGroundingCoverage: Double? = nil,
        minClaimCount: Int? = nil,
        expectedCompleteness: CompletenessAssessment? = nil,
        requireNonEmptyContent: Bool = true
    ) {
        self.minGroundingCoverage = minGroundingCoverage
        self.minClaimCount = minClaimCount
        self.expectedCompleteness = expectedCompleteness
        self.requireNonEmptyContent = requireNonEmptyContent
    }
}

// MARK: - Evaluation Metrics

/// Structured metrics captured from a single evaluation run.
///
/// All values are derived from existing pipeline types:
/// - `UnderstandingMetadata` for grounding, completeness, timing
/// - `ContextFrameMetadata` for context composition
/// - `UnderstandingClaim` for claim analysis
/// - `BudgetSummary` for budget utilization
struct EvaluationMetrics: Codable, Sendable, Equatable {

    // MARK: Grounding Metrics

    /// Fraction of context units referenced by at least one claim (GP-3).
    let groundingCoverage: Double

    /// Total claims produced.
    let totalClaims: Int

    /// Claims with at least one grounding reference.
    let groundedClaims: Int

    /// Distribution of claim types: factual, derived, interpretive, inferred.
    let claimTypeDistribution: [String: Int]

    // MARK: Context Metrics

    /// Total annotated units in the evidence set.
    let evidenceSetSize: Int

    /// Units selected into the context frame.
    let selectedCount: Int

    /// Fraction of evidence elided.
    let elisionRatio: Double

    /// Per-tier unit counts in the context frame.
    let tierDistribution: [String: Int]

    /// Per-stratum unit counts.
    let stratumDistribution: [String: Int]

    /// Tier degradation level.
    let degradationLevel: String

    /// Budget utilization ratio (0.0–1.0).
    let budgetUtilization: Double

    /// Total budget.
    let budgetTotal: Int

    /// Budget used.
    let budgetUsed: Int

    // MARK: Quality Metrics

    /// Completeness assessment.
    let completeness: String

    /// Length of the output content (characters).
    let contentLength: Int

    /// Number of distinct entities mentioned in claims.
    let entityCount: Int

    // MARK: Engine Metrics

    /// Reasoning engine identifier.
    let engineIdentifier: String

    /// Reasoning engine version.
    let engineVersion: String

    /// Whether the context frame was stale.
    let isStale: Bool
}

// MARK: - Evaluation Result

/// The outcome of evaluating a single case.
struct EvaluationResult: Codable, Sendable {
    /// The case identifier.
    let caseId: String

    /// The case name.
    let caseName: String

    /// The case category.
    let category: String

    /// When this evaluation was run.
    let timestamp: Date

    /// Captured metrics (nil if evaluation failed before producing output).
    let metrics: EvaluationMetrics?

    /// Whether the evaluation succeeded (produced an Understanding).
    let success: Bool

    /// Error description if the evaluation failed.
    let error: String?

    /// Expectation violations (empty if all expectations met).
    let violations: [ExpectationViolation]
}

/// A specific quality expectation that was not met.
struct ExpectationViolation: Codable, Sendable {
    /// What was expected.
    let expectation: String

    /// What was observed.
    let actual: String

    /// Human-readable description.
    let description: String
}

// MARK: - Evaluation Report

/// A complete evaluation run report.
struct EvaluationReport: Codable, Sendable {
    /// Unique identifier for this run.
    let runId: String

    /// When this run was executed.
    let timestamp: Date

    /// Engine version used.
    let engineVersion: String

    /// Individual case results.
    let results: [EvaluationResult]

    /// Aggregated summary.
    let summary: EvaluationSummary
}

/// Aggregated metrics across all cases in a run.
struct EvaluationSummary: Codable, Sendable {
    /// Total evaluation cases.
    let totalCases: Int

    /// Cases that produced an Understanding.
    let succeeded: Int

    /// Cases that failed to produce output.
    let failed: Int

    /// Cases where all expectations were met.
    let expectationsMet: Int

    /// Cases with at least one expectation violation.
    let expectationsViolated: Int

    /// Average grounding coverage across successful cases.
    let averageGroundingCoverage: Double

    /// Average claim count across successful cases.
    let averageClaimCount: Double

    /// Average content length across successful cases.
    let averageContentLength: Double

    /// Average budget utilization across successful cases.
    let averageBudgetUtilization: Double

    /// Completeness distribution: assessment → count.
    let completenessDistribution: [String: Int]

    /// Claim type totals across all cases.
    let totalClaimTypeDistribution: [String: Int]

    /// Average tier distribution across successful cases.
    let averageTierDistribution: [String: Double]
}

// MARK: - Baseline Comparison

/// Comparison between two evaluation runs.
struct BaselineComparison: Codable, Sendable {
    /// The baseline run identifier.
    let baselineRunId: String

    /// The current run identifier.
    let currentRunId: String

    /// Timestamp of comparison.
    let timestamp: Date

    /// Per-case metric deltas.
    let caseComparisons: [CaseComparison]

    /// Summary-level regressions detected.
    let regressions: [MetricRegression]

    /// Summary-level improvements detected.
    let improvements: [MetricImprovement]

    /// Whether the current run passes the baseline (no regressions exceed thresholds).
    let passesBaseline: Bool
}

/// Per-case comparison between baseline and current metrics.
struct CaseComparison: Codable, Sendable {
    let caseId: String
    let caseName: String
    let baselineMetrics: EvaluationMetrics?
    let currentMetrics: EvaluationMetrics?
    let regressions: [MetricRegression]
    let improvements: [MetricImprovement]
}

/// A metric that regressed beyond the configured threshold.
struct MetricRegression: Codable, Sendable {
    /// Which metric regressed.
    let metric: String

    /// Baseline value.
    let baselineValue: Double

    /// Current value.
    let currentValue: Double

    /// Absolute delta (current - baseline).
    let delta: Double

    /// Configured threshold that was exceeded.
    let threshold: Double
}

/// A metric that improved.
struct MetricImprovement: Codable, Sendable {
    /// Which metric improved.
    let metric: String

    /// Baseline value.
    let baselineValue: Double

    /// Current value.
    let currentValue: Double

    /// Absolute delta (current - baseline).
    let delta: Double
}

// MARK: - Comparison Thresholds

/// Configurable thresholds for regression detection.
///
/// A regression is flagged when a metric degrades beyond its threshold.
/// Positive thresholds mean "current must not drop below baseline - threshold."
/// Negative thresholds (for metrics where lower is better) mean "current must
/// not exceed baseline + threshold."
struct ComparisonThresholds: Sendable {
    /// Maximum allowed decrease in grounding coverage.
    let groundingCoverageThreshold: Double

    /// Maximum allowed decrease in claim count (fractional).
    let claimCountThreshold: Double

    /// Maximum allowed decrease in content length (fractional).
    let contentLengthThreshold: Double

    /// Maximum allowed decrease in budget utilization.
    let budgetUtilizationThreshold: Double

    /// Default thresholds — conservative for initial baseline.
    static let `default` = ComparisonThresholds(
        groundingCoverageThreshold: 0.1,
        claimCountThreshold: 0.2,
        contentLengthThreshold: 0.3,
        budgetUtilizationThreshold: 0.15
    )
}
