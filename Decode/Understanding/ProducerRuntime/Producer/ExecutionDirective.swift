// ExecutionDirective.swift — ProducerRuntime
// DDS-001: PC-2 (execution), PC-5 (batch execution), PC-9 (execution directives)
// IAG-001 §4: Public protocol, consumed by UpdateEngine
// IAG-003 §3.1: async — crosses ProducerActor boundary

import Foundation
import DIRCore

/// Accepts execution tickets and drives producer execution.
///
/// DDS-001 PC-9: The scheduling subsystem (UpdateEngine) issues execution tickets
/// specifying which producers to execute and over which scope.
/// DDS-001 PC-2: Individual producer execution with DAG ordering.
/// DDS-001 PC-5: Batch execution of all producers in DAG order.
///
/// IAG-003: All methods are async — they cross the ProducerActor boundary.
/// Implemented by ProducerActor, consumed by UpdateEngine.
public protocol ExecutionDirective: Sendable {

    /// Executes a single execution ticket.
    ///
    /// DDS-001 PC-2: Executes the specified producer over the specified scope.
    /// The producer receives its declared inputs from the DIR and output is
    /// validated and committed.
    ///
    /// - Parameter ticket: The execution ticket specifying producer and scope.
    /// - Returns: The execution result (completed with report, or failed).
    func execute(_ ticket: ExecutionTicket) async -> TicketResult

    /// Executes a batch of tickets in DAG order.
    ///
    /// DDS-001: Orders tickets according to the Pass DAG and executes each
    /// producer over its specified scope. Independent passes at the same
    /// topological level may execute concurrently (DAS-006 PE-2).
    ///
    /// - Parameter tickets: The execution tickets to process.
    /// - Returns: Results for each ticket, in the order they were processed.
    func executeBatch(_ tickets: [ExecutionTicket]) async -> [TicketResult]

    /// Executes all registered producers in full batch mode.
    ///
    /// DDS-001 PC-5: All frontends over all tracked files, then all passes
    /// in DAG order over their full scope. Functionally equivalent to
    /// processing a change set that touches every tracked file.
    ///
    /// - Parameter filePaths: All tracked source file paths.
    /// - Returns: Results for each producer execution.
    func executeBatchAll(filePaths: Set<String>) async -> [TicketResult]
}
