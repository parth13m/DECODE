// InvocationTypes.swift — ProducerRuntime
// DDS-003: Pass invocation lifecycle, execution context, scope window
// IAG-001 §2: DDS-003 contracts are internal to ProducerRuntime

import Foundation
import DIRCore

// MARK: — Invocation State

/// The lifecycle state of an individual pass invocation.
///
/// DDS-003 Invocation Lifecycle:
/// Assembling → Executing → Collecting → Completed / Failed
///            → Cancelled (from Assembling or Executing)
enum InvocationState: String, Hashable, Sendable {
    /// Resolving scope window and assembling input set from DIR.
    case assembling
    /// Pass implementation is running with its execution context.
    case executing
    /// Pass has returned raw output; output pipeline is processing.
    case collecting
    /// Invocation produced validated output batch and change report.
    case completed
    /// Invocation failed. No output produced.
    case failed
    /// Invocation was cancelled before completion. No output produced.
    case cancelled

    /// Whether this is a terminal state.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .assembling, .executing, .collecting: return false
        }
    }

    /// Returns whether transitioning to the given state is valid.
    func canTransition(to target: InvocationState) -> Bool {
        switch (self, target) {
        case (.assembling, .executing): return true
        case (.assembling, .cancelled): return true
        case (.executing, .collecting): return true
        case (.executing, .cancelled): return true
        case (.executing, .failed): return true
        case (.collecting, .completed): return true
        case (.collecting, .failed): return true
        default: return false
        }
    }
}

// MARK: — Scope Window

/// The concrete entity set determined by scope resolution for a specific invocation.
///
/// DDS-003: For a per-file pass processing file F, the scope window is all entities
/// in F. For a per-module pass, all entities in the module.
struct ScopeWindow: Sendable {
    /// The entities within scope for this invocation.
    let entities: Set<EntityReference>

    /// An identifier for this scope window (used for prior output record lookup).
    let identifier: ScopeWindowIdentifier

    init(entities: Set<EntityReference>, identifier: ScopeWindowIdentifier) {
        self.entities = entities
        self.identifier = identifier
    }
}

/// Identifies a scope window for prior output record lookup.
///
/// DDS-003: Prior output records are keyed by (pass identity, scope window).
struct ScopeWindowIdentifier: Hashable, Sendable {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    /// Creates a scope window identifier from an execution scope.
    static func from(_ scope: ExecutionScope) -> ScopeWindowIdentifier {
        switch scope {
        case .entity(let ref):
            return ScopeWindowIdentifier("entity:\(ref.qualifiedName)")
        case .file(let path):
            return ScopeWindowIdentifier("file:\(path)")
        case .module(let name):
            return ScopeWindowIdentifier("module:\(name)")
        case .system:
            return ScopeWindowIdentifier("system")
        case .files(let paths):
            return ScopeWindowIdentifier("files:\(paths.sorted().joined(separator: ","))")
        }
    }
}

// MARK: — Execution Context

/// The runtime package provided to a pass when it is invoked.
///
/// DDS-003: The execution context is the pass's complete view of the world.
/// A pass interacts with the system only through its execution context.
///
/// Not included (DDS-003): raw source code, other passes' state, DAG structure,
/// uncommitted output from concurrent passes.
struct ExecutionContext: Sendable {
    /// The assembled input units (read-only snapshot from DIR).
    let inputSet: [AtomicUnit]

    /// The entity set being processed.
    let scopeWindow: ScopeWindow

    /// The pass's identifier and version.
    let passIdentity: ProducerIdentity

    /// The pass's declared output contract — constrains what the pass may produce.
    let outputContract: OutputContract

    /// Budget information for semantic passes. Nil for deterministic passes.
    /// DAS-006 SP-4: cost model for semantic passes.
    let budget: SemanticBudget?

    /// For composition passes: the existing scope-level entity if one exists.
    /// DDS-003 CE-1: if absent, composition pass may create one.
    let existingScopeEntity: EntityReference?

    init(
        inputSet: [AtomicUnit],
        scopeWindow: ScopeWindow,
        passIdentity: ProducerIdentity,
        outputContract: OutputContract,
        budget: SemanticBudget? = nil,
        existingScopeEntity: EntityReference? = nil
    ) {
        self.inputSet = inputSet
        self.scopeWindow = scopeWindow
        self.passIdentity = passIdentity
        self.outputContract = outputContract
        self.budget = budget
        self.existingScopeEntity = existingScopeEntity
    }
}

/// Budget information for semantic pass execution.
///
/// DAS-006 SP-4: semantic passes receive cost budget information.
struct SemanticBudget: Sendable {
    /// Remaining invocation count within the scheduling window.
    let remainingInvocations: Int

    /// The inference method identifier (model, prompt template version).
    let inferenceMethod: String

    init(remainingInvocations: Int, inferenceMethod: String) {
        self.remainingInvocations = remainingInvocations
        self.inferenceMethod = inferenceMethod
    }
}
