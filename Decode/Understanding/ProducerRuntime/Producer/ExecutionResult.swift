// ExecutionResult.swift — ProducerRuntime
// DDS-001: PC-2 — execution result includes output and change report
// DDS-003: PC-3 — changed output detection result

import Foundation
import DIRCore

/// The result of executing a single execution ticket.
///
/// DDS-001 PC-2: execution completes with output committed and a change report,
/// or fails with a failure record.
public enum TicketResult: Sendable {
    /// The producer executed successfully.
    case completed(ExecutionReport)
    /// The producer failed.
    case failed(FailureRecord)
}

/// Report from a successful producer execution.
///
/// DDS-001: Includes the change report (from DDS-003:PC-3) and metrics.
public struct ExecutionReport: Sendable {
    /// The producer that executed.
    public let producerIdentity: ProducerIdentity

    /// The scope that was processed.
    public let scope: ExecutionScope

    /// Whether the output differed from the prior invocation's output.
    public let changeReport: ChangeReport

    /// Number of units in the output batch.
    public let outputUnitCount: Int

    /// Number of units in the input set.
    public let inputUnitCount: Int

    /// How long execution took.
    public let duration: Duration

    public init(
        producerIdentity: ProducerIdentity,
        scope: ExecutionScope,
        changeReport: ChangeReport,
        outputUnitCount: Int,
        inputUnitCount: Int,
        duration: Duration
    ) {
        self.producerIdentity = producerIdentity
        self.scope = scope
        self.changeReport = changeReport
        self.outputUnitCount = outputUnitCount
        self.inputUnitCount = inputUnitCount
        self.duration = duration
    }
}

/// The result of comparing new output against prior output.
///
/// DDS-003 PC-3: Changed output detection determines whether output differs
/// from the prior invocation. Enables early termination (DAS-006 PE-5).
public enum ChangeReport: Sendable {
    /// Complete bidirectional match — every new unit has a prior counterpart
    /// and vice versa. Cascade may be terminated.
    case noChange
    /// At least one unit was added, removed, or modified.
    /// The scheduling subsystem must propagate the change downstream.
    case changed(ChangeDetail)
    /// First invocation — no prior output to compare against.
    /// Always reported as changed by definition (DDS-003 PC-3).
    case firstInvocation
}

/// Details of what changed in the output.
///
/// DDS-003: At least one unit was added, removed, or modified
/// (different value, tier, or confidence).
public struct ChangeDetail: Hashable, Sendable {
    /// Number of units added (present in new output, absent in prior).
    public let addedCount: Int
    /// Number of units removed (present in prior, absent in new output).
    public let removedCount: Int
    /// Number of units modified (same supersession key, different value/confidence).
    public let modifiedCount: Int

    public init(addedCount: Int, removedCount: Int, modifiedCount: Int) {
        self.addedCount = addedCount
        self.removedCount = removedCount
        self.modifiedCount = modifiedCount
    }
}
