// ExecutionTicket.swift — ProducerRuntime
// DDS-001: PC-9 — execution directives specify producer, scope, and mode
// DDS-001: PC-2 (incremental), PC-5 (batch)

import Foundation
import DIRCore

/// Whether an execution is batch (full rebuild) or incremental (scoped).
///
/// DDS-001: Batch execution processes all tracked files; incremental
/// processes only the specified scope.
public enum ExecutionMode: String, Hashable, Codable, Sendable {
    /// Full rebuild — all frontends over all files, all passes over full scope.
    case batch
    /// Scoped re-execution — specific producer over specific scope.
    case incremental
}

/// A unit of work issued to the Producer Runtime via PC-9.
///
/// DDS-001: An execution ticket carries the producer identity, the scope,
/// and whether the execution is batch or incremental.
public struct ExecutionTicket: Hashable, Sendable {
    /// The producer to execute.
    public let producerId: ProducerIdentifier

    /// The scope of execution.
    public let scope: ExecutionScope

    /// Batch or incremental.
    public let mode: ExecutionMode

    public init(
        producerId: ProducerIdentifier,
        scope: ExecutionScope,
        mode: ExecutionMode
    ) {
        self.producerId = producerId
        self.scope = scope
        self.mode = mode
    }
}

/// The scope specified in an execution ticket.
///
/// DDS-003: Scope must match the pass's declared scope granularity.
/// For frontends, scope specifies which files to process.
public enum ExecutionScope: Hashable, Sendable {
    /// A single entity.
    case entity(EntityReference)
    /// All entities in a specific file.
    case file(path: String)
    /// All entities in a module.
    case module(name: String)
    /// All entities in the system (full scope).
    case system
    /// Multiple files (used for batch frontend execution).
    case files(paths: Set<String>)
}
