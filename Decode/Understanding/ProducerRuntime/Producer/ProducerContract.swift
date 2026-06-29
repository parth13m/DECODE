// ProducerContract.swift — ProducerRuntime
// DDS-001: PC-1 — producer registration contracts
// DAS-006: Pass Contract — input contract, output contract, scope, tier range,
//          determinism, idempotency
// DAS-002: Frontend contract — source formats, output predicates

import Foundation
import DIRCore

// MARK: — Producer Identity

/// Uniquely identifies a registered producer within the Producer Runtime.
///
/// DDS-001: producer identity is used for provenance records, DAG edges,
/// failure reports, and discovery queries.
public struct ProducerIdentifier: Hashable, Codable, Sendable {
    /// Unique name for the producer (e.g., "swift-syntax-frontend", "identity-pass").
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

extension ProducerIdentifier: CustomStringConvertible {
    public var description: String { name }
}

/// The version of a producer implementation.
///
/// DAS-010 PU-1: version changes trigger upgrade-based re-evaluation.
public struct ProducerVersion: Hashable, Codable, Sendable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }
}

extension ProducerVersion: CustomStringConvertible {
    public var description: String { "\(major).\(minor)" }
}

extension ProducerVersion: Comparable {
    public static func < (lhs: ProducerVersion, rhs: ProducerVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }
}

/// The identity of a producer: its identifier and version.
public struct ProducerIdentity: Hashable, Codable, Sendable {
    public let identifier: ProducerIdentifier
    public let version: ProducerVersion

    public init(identifier: ProducerIdentifier, version: ProducerVersion) {
        self.identifier = identifier
        self.version = version
    }
}

// MARK: — Producer Kind

/// Whether a producer is a frontend or a pass.
///
/// DAS-002: Frontends read source material and emit T0 units.
///          Passes read DIR content and produce units at the same or higher tier.
public enum ProducerKind: String, Hashable, Codable, Sendable {
    /// Reads source material (files) and emits T0 units.
    case frontend
    /// Reads DIR content and produces derived or inferred units.
    case pass
}

// MARK: — Execution Strategy

/// The execution strategy for a producer, determined by its output tier.
///
/// DDS-003: Deterministic (T0/T1) vs Semantic (T2). Composition is orthogonal,
/// not a third strategy.
public enum ExecutionStrategy: String, Hashable, Codable, Sendable {
    /// T0/T1 output. No AI invocation, bounded execution time, idempotent.
    case deterministic
    /// T2 output. AI service dependency, no latency bound, non-idempotent.
    case semantic
}

// MARK: — Scope Granularity

/// The granularity at which a pass processes the codebase.
///
/// DDS-003: Scope resolution maps this to a concrete entity set per invocation.
/// DAS-006 PC-SCOPE-1: scope determines incremental granularity.
public enum ScopeGranularity: String, Hashable, Codable, Sendable {
    /// Processes one entity at a time.
    case perEntity
    /// Processes all entities in a single file.
    case perFile
    /// Processes all entities in a module.
    case perModule
    /// Processes all entities in the system.
    case perSystem
}

// MARK: — Input Contract

/// Declares what DIR content a pass requires as input.
///
/// DDS-003: Input assembly uses this contract to query the DIR
/// and construct the input set for each invocation.
/// DAS-006 PC-IN-1: only units at declared tiers are included.
public struct InputContract: Hashable, Codable, Sendable {
    /// The predicates this pass reads from the DIR.
    public let predicates: Set<PredicateIdentifier>

    /// The tiers this pass accepts as input. Only units at these tiers
    /// are included in the input set.
    public let tiers: Set<Tier>

    public init(predicates: Set<PredicateIdentifier>, tiers: Set<Tier>) {
        self.predicates = predicates
        self.tiers = tiers
    }
}

// MARK: — Output Contract

/// Declares what a producer is allowed to emit.
///
/// DDS-001 R4: output validation rejects units with predicates or tiers
/// outside the declared output contract.
public struct OutputContract: Hashable, Codable, Sendable {
    /// The predicates this producer may emit.
    public let predicates: Set<PredicateIdentifier>

    /// The tier range this producer may emit (inclusive).
    /// DDS-001: deterministic producers must emit T0 or T1 only.
    ///          Semantic producers must emit T2 only.
    public let tierRange: ClosedRange<Tier>

    public init(predicates: Set<PredicateIdentifier>, tierRange: ClosedRange<Tier>) {
        self.predicates = predicates
        self.tierRange = tierRange
    }
}

// MARK: — Frontend Contract

/// The declared contract for a frontend producer.
///
/// DAS-002: Frontends read source material in a specific language/format
/// and emit T0 atomic units.
public struct FrontendContract: Hashable, Codable, Sendable {
    /// The producer's identity (name + version).
    public let identity: ProducerIdentity

    /// The source file extensions this frontend handles (e.g., ["swift"]).
    public let sourceFormats: Set<String>

    /// What the frontend is allowed to produce.
    public let outputContract: OutputContract

    public init(
        identity: ProducerIdentity,
        sourceFormats: Set<String>,
        outputContract: OutputContract
    ) {
        self.identity = identity
        self.sourceFormats = sourceFormats
        self.outputContract = outputContract
    }
}

// MARK: — Pass Contract

/// The declared contract for a pass producer.
///
/// DAS-006: Complete pass contract includes input, output, scope,
/// tier range, determinism, and idempotency.
public struct PassContract: Hashable, Codable, Sendable {
    /// The pass's identity (name + version).
    public let identity: ProducerIdentity

    /// What DIR content the pass reads.
    public let inputContract: InputContract

    /// What the pass is allowed to produce.
    public let outputContract: OutputContract

    /// The granularity at which the pass processes the codebase.
    public let scope: ScopeGranularity

    /// The execution strategy (deterministic or semantic).
    public let executionStrategy: ExecutionStrategy

    /// Whether the pass is a composition pass (DAS-006 CP-1 through CP-4).
    /// Composition is orthogonal to execution strategy.
    public let isComposition: Bool

    /// Whether the pass is idempotent.
    /// DAS-006 PC-IDEM-1: deterministic passes must be idempotent.
    /// DAS-006 PC-IDEM-2: semantic passes are presumed non-idempotent.
    public let isIdempotent: Bool

    /// The identifiers of passes whose output this pass depends on.
    /// DAS-006 PD-1: dependencies are declared, not discovered.
    public let dependencies: Set<ProducerIdentifier>

    public init(
        identity: ProducerIdentity,
        inputContract: InputContract,
        outputContract: OutputContract,
        scope: ScopeGranularity,
        executionStrategy: ExecutionStrategy,
        isComposition: Bool,
        isIdempotent: Bool,
        dependencies: Set<ProducerIdentifier>
    ) {
        self.identity = identity
        self.inputContract = inputContract
        self.outputContract = outputContract
        self.scope = scope
        self.executionStrategy = executionStrategy
        self.isComposition = isComposition
        self.isIdempotent = isIdempotent
        self.dependencies = dependencies
    }
}

// MARK: — Unified Producer Contract

/// A registered producer's full contract — either frontend or pass.
///
/// DDS-001 PC-1: the registry stores contracts; ProducerContract is
/// the registry's per-producer record.
public enum ProducerContract: Sendable {
    case frontend(FrontendContract)
    case pass(PassContract)

    /// The producer's identity regardless of kind.
    public var identity: ProducerIdentity {
        switch self {
        case .frontend(let c): return c.identity
        case .pass(let c): return c.identity
        }
    }

    /// The producer's output contract regardless of kind.
    public var outputContract: OutputContract {
        switch self {
        case .frontend(let c): return c.outputContract
        case .pass(let c): return c.outputContract
        }
    }

    /// The kind of producer (frontend or pass).
    public var kind: ProducerKind {
        switch self {
        case .frontend: return .frontend
        case .pass: return .pass
        }
    }
}
