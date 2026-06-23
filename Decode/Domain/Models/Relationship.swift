import Foundation

/// A directed, typed edge between two code entities discovered during AST analysis.
///
/// Relationships are the Deterministic Facts Engine's representation of
/// structural connections within (and eventually across) source files.
/// Each relationship records an objective, provable connection: entity A
/// has relationship of kind K to target B, observed at a specific line.
///
/// Four relationship kinds are currently extracted:
/// - `.calls` — entity A calls function B
/// - `.conformsTo` — type A conforms to protocol/interface B
/// - `.inherits` — type A inherits from type B
/// - `.owns` — type A owns member B (nested type or stored property)
///
/// Future kinds (`.references`) add cases to ``RelationshipKind``
/// without changing this struct.
///
/// ## Identity Model
/// - `sourceEntity`: the `stableId` (body hash) of the entity where the
///   relationship originates. Deterministic and unique within a file.
/// - `targetName`: the symbolic name of the target. For `.calls`, this is
///   the function/method name at the call site (e.g., `"validate"`,
///   `"self.configure"`). The target may or may not be defined in this file.
///
/// ## Resolution
/// Whether a `targetName` corresponds to an entity in the same file can be
/// determined by matching against the file's entity list. This is a consumer
/// concern, not a parser concern — the parser records what it observes.
struct Relationship: Sendable, Hashable {

    /// The kind of structural connection.
    let kind: RelationshipKind

    /// The `stableId` of the entity where this relationship originates.
    let sourceEntity: String

    /// The symbolic name of the target (function name, type name, etc.).
    let targetName: String

    /// 1-based line number where this relationship was observed in the source.
    let line: Int
}

/// The structural category of a relationship between code entities.
///
/// Each case represents a distinct, objectively provable connection type.
/// New cases are added as the Deterministic Facts Engine gains extractors
/// for additional relationship types.
enum RelationshipKind: String, Sendable, Codable, Hashable {

    /// Entity A calls function/method B.
    ///
    /// Extracted from function call expressions in the AST.
    /// The target name is the direct callee identifier — qualified with
    /// `self.` or `Type.` when the call site uses explicit qualification.
    case calls

    /// Type A conforms to protocol/interface B.
    ///
    /// Swift: `struct User: Codable` → conformsTo "Codable"
    /// Java: `class Foo implements Runnable` → conformsTo "Runnable"
    /// TypeScript: `class Foo implements Bar` → conformsTo "Bar"
    /// C#: `class Foo : IDisposable` (interface) → conformsTo "IDisposable"
    /// Python: not applicable (duck typing, no interface declarations)
    case conformsTo

    /// Type A inherits from type B.
    ///
    /// Swift: `class LoginManager: BaseManager` → inherits "BaseManager"
    /// Python: `class Foo(Bar)` → inherits "Bar"
    /// Java: `class Foo extends Bar` → inherits "Bar"
    /// C++: `class Foo : public Bar` → inherits "Bar"
    case inherits

    /// Type A owns member B (nested type or stored property).
    ///
    /// Nested type: `class SessionManager { struct Config {} }` → owns "Config"
    /// Stored property: `class SessionManager { let parser: SwiftParser }` → owns "parser"
    ///
    /// Ownership represents structural containment — the parent type
    /// defines or declares the target as part of its structure.
    case owns
}
