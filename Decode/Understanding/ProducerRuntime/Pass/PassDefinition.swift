// PassDefinition.swift — ProducerRuntime
// DDS-003: PC-1 — pass invocation contract
// DDS-003: R4 — execution strategies (deterministic, semantic)
// IAG-001 §2: DDS-003 contracts are internal protocols within ProducerRuntime

import Foundation
import DIRCore

/// The protocol that actual pass implementations conform to.
///
/// DDS-003 PC-1: A pass receives an execution context (assembled input set,
/// scope window, identity, output contract) and returns raw output records.
/// The pass interacts with the system only through its execution context.
///
/// Internal to ProducerRuntime per IAG-001 §2 — DDS-003 has a single consumer (DDS-001).
protocol PassDefinition: Sendable {

    /// Execute the pass over the given execution context.
    ///
    /// DDS-003 R4: The pass processes the input set and returns raw output records.
    /// The pass must check `Task.isCancelled` at natural checkpoints for
    /// cooperative cancellation (DDS-003 PC-4).
    ///
    /// - Parameter context: The complete runtime package for this invocation.
    /// - Returns: Raw output records (before provenance stamping).
    /// - Throws: On execution error (DDS-003 FM-1). The Pass Runtime catches the
    ///           error and treats the invocation as failed.
    func execute(context: ExecutionContext) async throws -> [RawOutputRecord]
}

/// The protocol that frontend implementations conform to.
///
/// Frontends read source material (files) and emit T0 atomic units.
/// They operate on raw file content, not DIR content.
protocol FrontendDefinition: Sendable {

    /// Parse the source file at the given path and return raw output records.
    ///
    /// - Parameters:
    ///   - filePath: Path to the source file.
    ///   - identity: The frontend's identity for provenance.
    ///   - outputContract: Constrains what the frontend may produce.
    /// - Returns: Raw output records for the file.
    /// - Throws: On parse error or I/O error (DDS-001 FM-1, FM-7).
    func parse(
        filePath: String,
        identity: ProducerIdentity,
        outputContract: OutputContract
    ) async throws -> [RawOutputRecord]
}
