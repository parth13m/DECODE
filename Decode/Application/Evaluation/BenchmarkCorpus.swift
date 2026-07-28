// BenchmarkCorpus.swift — Decode Application
// E1-01: Canonical Benchmark Corpus — 20+ cases that permanently measure
// Decode's understanding pipeline intelligence.
//
// Cases are organized by category and progressively increase in difficulty.
// Entity names use the pipeline's actual naming conventions:
//   - Top-level: "ClassName"
//   - Nested: "ParentName.childName"
//   - File: "file:FileName.ext"
//   - Relationship predicates: "calls", "conformsTo", "inherits", "owns", "contains"
//   - Evidence stages: "direct", "relational", "scope"
//   - Tiers: "t0" (deterministic)

import Foundation
import ConsumerRuntime

// MARK: - Benchmark Corpus

/// The canonical benchmark corpus for evaluating Decode's understanding pipeline.
///
/// All cases are defined in code for compile-time validation. The corpus provides
/// auto-discovery via `allCases` and category-filtered access via `cases(for:)`.
///
/// ## Usage
/// ```swift
/// let cases = BenchmarkCorpus.allCases          // all 22 cases
/// let single = BenchmarkCorpus.cases(for: .entityDiscovery) // category filter
/// let runner = BenchmarkRunner(understandingSystem: system, engineVersion: "1.0.0")
/// let report = await runner.run(cases: cases)
/// ```
enum BenchmarkCorpus {

    /// All canonical benchmark cases, ordered by category then difficulty.
    static let allCases: [BenchmarkCase] = [
        // Single File — Entity Discovery (5 cases)
        singleFileSimpleClass,
        singleFileStructWithMethods,
        singleFileEnumWithCases,
        singleFileProtocolDefinition,
        singleFilePythonClass,

        // Relationships (4 cases)
        relationshipProtocolConformance,
        relationshipClassInheritance,
        relationshipMethodCalls,
        relationshipNestedTypes,

        // Cross File (3 cases)
        crossFileProtocolImpl,
        crossFileTypeUsage,
        crossFileImportChain,

        // Data Flow (3 cases)
        dataFlowPipeline,
        dataFlowRepository,
        dataFlowPythonTransform,

        // Dependency Injection (2 cases)
        diProtocolAbstraction,
        diServiceLayer,

        // Architecture (2 cases)
        architectureMVVM,
        architectureCoordinator,

        // Edge Cases (3 cases)
        edgeCaseEmptyStruct,
        edgeCaseSingleFunction,
        edgeCaseDeeplyNested,
    ]

    /// Returns benchmark cases filtered by category.
    static func cases(for category: BenchmarkCategory) -> [BenchmarkCase] {
        allCases.filter { $0.category == category }
    }

    /// Returns a single benchmark case by ID, or nil if not found.
    static func findCase(id: String) -> BenchmarkCase? {
        allCases.first { $0.id == id }
    }

    /// All category identifiers present in the corpus.
    static var coveredCategories: Set<BenchmarkCategory> {
        Set(allCases.map(\.category))
    }

    // MARK: - Single File — Entity Discovery

    /// Case 1: Simple Swift class with methods and properties.
    /// Validates basic entity extraction: class, methods, properties.
    static let singleFileSimpleClass = BenchmarkCase(
        id: "sf-01-simple-class",
        name: "Simple Swift Class",
        description: "Validates entity extraction for a class with methods and properties",
        category: .entityDiscovery,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "UserService.swift",
                content: """
                import Foundation

                class UserService {
                    var users: [String] = []

                    func addUser(_ name: String) {
                        users.append(name)
                    }

                    func removeUser(_ name: String) {
                        users.removeAll { $0 == name }
                    }

                    func allUsers() -> [String] {
                        return users
                    }
                }
                """
            )
        ],
        queryEntity: "UserService",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "UserService",
                "UserService.users",
                "UserService.addUser",
                "UserService.removeUser",
                "UserService.allUsers"
            ],
            expectedPredicates: ["kind", "signature"],
            minEvidenceCount: 3,
            expectedStages: Set(["direct"]),
            expectedTiers: Set(["t0"]),
            requireSuccess: true
        )
    )

    /// Case 2: Swift struct with computed properties and methods.
    static let singleFileStructWithMethods = BenchmarkCase(
        id: "sf-02-struct-methods",
        name: "Struct with Methods",
        description: "Validates struct entity extraction including computed properties",
        category: .entityDiscovery,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Point.swift",
                content: """
                import Foundation

                struct Point {
                    let x: Double
                    let y: Double

                    var magnitude: Double {
                        return (x * x + y * y).squareRoot()
                    }

                    func distance(to other: Point) -> Double {
                        let dx = x - other.x
                        let dy = y - other.y
                        return (dx * dx + dy * dy).squareRoot()
                    }

                    func translated(dx: Double, dy: Double) -> Point {
                        return Point(x: x + dx, y: y + dy)
                    }
                }
                """
            )
        ],
        queryEntity: "Point",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Point",
                "Point.x",
                "Point.y",
                "Point.magnitude",
                "Point.distance",
                "Point.translated"
            ],
            expectedPredicates: ["kind", "signature"],
            minEvidenceCount: 3,
            expectedTiers: Set(["t0"]),
            requireSuccess: true
        )
    )

    /// Case 3: Swift enum with associated values and methods.
    static let singleFileEnumWithCases = BenchmarkCase(
        id: "sf-03-enum-cases",
        name: "Enum with Associated Values",
        description: "Validates enum entity extraction including cases with payloads",
        category: .entityDiscovery,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Result.swift",
                content: """
                import Foundation

                enum NetworkResult {
                    case success(data: Data)
                    case failure(error: Error)
                    case loading
                    case idle

                    var isComplete: Bool {
                        switch self {
                        case .success, .failure: return true
                        case .loading, .idle: return false
                        }
                    }

                    func map<T>(_ transform: (Data) -> T) -> T? {
                        if case .success(let data) = self {
                            return transform(data)
                        }
                        return nil
                    }
                }
                """
            )
        ],
        queryEntity: "NetworkResult",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "NetworkResult",
                "NetworkResult.isComplete",
                "NetworkResult.map"
            ],
            expectedPredicates: ["kind"],
            minEvidenceCount: 2,
            expectedTiers: Set(["t0"]),
            requireSuccess: true
        )
    )

    /// Case 4: Swift protocol with method requirements.
    static let singleFileProtocolDefinition = BenchmarkCase(
        id: "sf-04-protocol-def",
        name: "Protocol Definition",
        description: "Validates protocol entity extraction with requirements",
        category: .entityDiscovery,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Repository.swift",
                content: """
                import Foundation

                protocol Repository {
                    associatedtype Entity

                    func findAll() -> [Entity]
                    func findById(_ id: String) -> Entity?
                    func save(_ entity: Entity)
                    func delete(_ id: String)
                }
                """
            )
        ],
        queryEntity: "Repository",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Repository",
                "Repository.findAll",
                "Repository.findById",
                "Repository.save",
                "Repository.delete"
            ],
            expectedPredicates: ["kind"],
            minEvidenceCount: 2,
            requireSuccess: true
        )
    )

    /// Case 5: Python class with methods — validates TreeSitter frontend.
    static let singleFilePythonClass = BenchmarkCase(
        id: "sf-05-python-class",
        name: "Python Class",
        description: "Validates TreeSitter-based entity extraction for Python",
        category: .entityDiscovery,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "calculator.py",
                content: """
                class Calculator:
                    def __init__(self):
                        self.history = []

                    def add(self, a, b):
                        result = a + b
                        self.history.append(result)
                        return result

                    def subtract(self, a, b):
                        result = a - b
                        self.history.append(result)
                        return result

                    def get_history(self):
                        return list(self.history)
                """
            )
        ],
        queryEntity: "Calculator",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Calculator",
                "Calculator.__init__",
                "Calculator.add",
                "Calculator.subtract",
                "Calculator.get_history"
            ],
            expectedPredicates: ["kind"],
            minEvidenceCount: 2,
            requireSuccess: true
        )
    )

    // MARK: - Relationships

    /// Case 6: Protocol conformance — class conforming to protocol.
    static let relationshipProtocolConformance = BenchmarkCase(
        id: "rel-01-protocol-conformance",
        name: "Protocol Conformance",
        description: "Validates conformsTo relationship extraction",
        category: .relationshipResolution,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Printable.swift",
                content: """
                import Foundation

                protocol Printable {
                    var description: String { get }
                    func prettyPrint()
                }

                class Document: Printable {
                    let title: String
                    let content: String

                    init(title: String, content: String) {
                        self.title = title
                        self.content = content
                    }

                    var description: String {
                        return "\\(title): \\(content)"
                    }

                    func prettyPrint() {
                        print("=== \\(title) ===")
                        print(content)
                    }
                }
                """
            )
        ],
        queryEntity: "Document",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Document",
                "Printable",
                "Document.title",
                "Document.content"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "Document", predicate: "conformsTo", target: "Printable")
            ],
            expectedPredicates: ["kind"],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    /// Case 7: Class inheritance.
    static let relationshipClassInheritance = BenchmarkCase(
        id: "rel-02-class-inheritance",
        name: "Class Inheritance",
        description: "Validates inherits/conformsTo relationship for class hierarchy",
        category: .relationshipResolution,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Shapes.swift",
                content: """
                import Foundation

                class Shape {
                    var name: String

                    init(name: String) {
                        self.name = name
                    }

                    func area() -> Double {
                        return 0
                    }
                }

                class Circle: Shape {
                    let radius: Double

                    init(radius: Double) {
                        self.radius = radius
                        super.init(name: "Circle")
                    }

                    override func area() -> Double {
                        return Double.pi * radius * radius
                    }
                }

                class Rectangle: Shape {
                    let width: Double
                    let height: Double

                    init(width: Double, height: Double) {
                        self.width = width
                        self.height = height
                        super.init(name: "Rectangle")
                    }

                    override func area() -> Double {
                        return width * height
                    }
                }
                """
            )
        ],
        queryEntity: "Circle",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Shape",
                "Circle",
                "Rectangle",
                "Circle.radius"
            ],
            expectedRelationships: [
                // Note: SwiftSyntax records all inheritance clause items as conformsTo
                ExpectedRelationship(source: "Circle", predicate: "conformsTo", target: "Shape"),
                ExpectedRelationship(source: "Rectangle", predicate: "conformsTo", target: "Shape")
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    /// Case 8: Method calls between functions.
    static let relationshipMethodCalls = BenchmarkCase(
        id: "rel-03-method-calls",
        name: "Method Calls",
        description: "Validates call relationship extraction between methods",
        category: .relationshipResolution,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Pipeline.swift",
                content: """
                import Foundation

                class DataPipeline {
                    func process(input: String) -> String {
                        let validated = validate(input)
                        let transformed = transform(validated)
                        return format(transformed)
                    }

                    func validate(_ input: String) -> String {
                        return input.trimmingCharacters(in: .whitespaces)
                    }

                    func transform(_ input: String) -> String {
                        return input.uppercased()
                    }

                    func format(_ input: String) -> String {
                        return "[\\(input)]"
                    }
                }
                """
            )
        ],
        queryEntity: "DataPipeline",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "DataPipeline",
                "DataPipeline.process",
                "DataPipeline.validate",
                "DataPipeline.transform",
                "DataPipeline.format"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "DataPipeline.process", predicate: "calls", target: "validate"),
                ExpectedRelationship(source: "DataPipeline.process", predicate: "calls", target: "transform"),
                ExpectedRelationship(source: "DataPipeline.process", predicate: "calls", target: "format")
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    /// Case 9: Nested types — struct inside class.
    static let relationshipNestedTypes = BenchmarkCase(
        id: "rel-04-nested-types",
        name: "Nested Types",
        description: "Validates ownership relationship for nested type declarations",
        category: .relationshipResolution,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Configuration.swift",
                content: """
                import Foundation

                class AppConfiguration {
                    struct DatabaseConfig {
                        let host: String
                        let port: Int
                        let name: String
                    }

                    struct NetworkConfig {
                        let baseURL: String
                        let timeout: TimeInterval
                    }

                    let database: DatabaseConfig
                    let network: NetworkConfig

                    init(database: DatabaseConfig, network: NetworkConfig) {
                        self.database = database
                        self.network = network
                    }
                }
                """
            )
        ],
        queryEntity: "AppConfiguration",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "AppConfiguration",
                "AppConfiguration.DatabaseConfig",
                "AppConfiguration.NetworkConfig",
                "AppConfiguration.database",
                "AppConfiguration.network"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "AppConfiguration", predicate: "owns", target: "DatabaseConfig"),
                ExpectedRelationship(source: "AppConfiguration", predicate: "owns", target: "NetworkConfig")
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    // MARK: - Cross File

    /// Case 10: Protocol defined in one file, implemented in another.
    static let crossFileProtocolImpl = BenchmarkCase(
        id: "cf-01-protocol-impl",
        name: "Cross-File Protocol Implementation",
        description: "Validates cross-file entity resolution with protocol + conformance",
        category: .crossFileResolution,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Storage.swift",
                content: """
                import Foundation

                protocol StorageProtocol {
                    func save(key: String, value: String)
                    func load(key: String) -> String?
                    func delete(key: String)
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "FileStorage.swift",
                content: """
                import Foundation

                class FileStorage: StorageProtocol {
                    private var store: [String: String] = [:]

                    func save(key: String, value: String) {
                        store[key] = value
                    }

                    func load(key: String) -> String? {
                        return store[key]
                    }

                    func delete(key: String) {
                        store.removeValue(forKey: key)
                    }
                }
                """
            )
        ],
        queryEntity: "FileStorage",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "FileStorage",
                "StorageProtocol",
                "FileStorage.save",
                "FileStorage.load",
                "FileStorage.delete"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "FileStorage", predicate: "conformsTo", target: "StorageProtocol")
            ],
            minEvidenceCount: 3,
            expectedStages: Set(["direct"]),
            requireSuccess: true
        )
    )

    /// Case 11: Type defined in one file, used as property in another.
    static let crossFileTypeUsage = BenchmarkCase(
        id: "cf-02-type-usage",
        name: "Cross-File Type Usage",
        description: "Validates cross-file entity discovery when types span files",
        category: .crossFileResolution,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "User.swift",
                content: """
                import Foundation

                struct User {
                    let id: String
                    let name: String
                    let email: String
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "UserStore.swift",
                content: """
                import Foundation

                class UserStore {
                    private var users: [User] = []

                    func add(_ user: User) {
                        users.append(user)
                    }

                    func find(byId id: String) -> User? {
                        return users.first { $0.id == id }
                    }

                    func all() -> [User] {
                        return users
                    }
                }
                """
            )
        ],
        queryEntity: "UserStore",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "UserStore",
                "User",
                "UserStore.add",
                "UserStore.find",
                "UserStore.all"
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    /// Case 12: Three files forming an import chain.
    static let crossFileImportChain = BenchmarkCase(
        id: "cf-03-import-chain",
        name: "Cross-File Import Chain",
        description: "Validates entity discovery across a three-file dependency chain",
        category: .crossFileResolution,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Logger.swift",
                content: """
                import Foundation

                class Logger {
                    func log(_ message: String) {
                        print("[LOG] \\(message)")
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "NetworkClient.swift",
                content: """
                import Foundation

                class NetworkClient {
                    let logger: Logger

                    init(logger: Logger) {
                        self.logger = logger
                    }

                    func fetch(url: String) -> String {
                        logger.log("Fetching \\(url)")
                        return "response"
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "APIService.swift",
                content: """
                import Foundation

                class APIService {
                    let client: NetworkClient

                    init(client: NetworkClient) {
                        self.client = client
                    }

                    func getUsers() -> String {
                        return client.fetch(url: "/users")
                    }
                }
                """
            )
        ],
        queryEntity: "APIService",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "APIService",
                "NetworkClient",
                "APIService.getUsers",
                "APIService.client"
            ],
            minEvidenceCount: 2,
            requireSuccess: true
        )
    )

    // MARK: - Data Flow

    /// Case 13: Data transformation pipeline.
    static let dataFlowPipeline = BenchmarkCase(
        id: "df-01-pipeline",
        name: "Data Transform Pipeline",
        description: "Validates entity/call extraction in a data transformation chain",
        category: .moduleContext,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "TextProcessor.swift",
                content: """
                import Foundation

                class TextProcessor {
                    func process(_ input: String) -> String {
                        let cleaned = clean(input)
                        let tokens = tokenize(cleaned)
                        let filtered = filter(tokens)
                        return join(filtered)
                    }

                    func clean(_ text: String) -> String {
                        return text.trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                    }

                    func tokenize(_ text: String) -> [String] {
                        return text.components(separatedBy: " ")
                    }

                    func filter(_ tokens: [String]) -> [String] {
                        return tokens.filter { $0.count > 2 }
                    }

                    func join(_ tokens: [String]) -> String {
                        return tokens.joined(separator: " ")
                    }
                }
                """
            )
        ],
        queryEntity: "TextProcessor",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "TextProcessor",
                "TextProcessor.process",
                "TextProcessor.clean",
                "TextProcessor.tokenize",
                "TextProcessor.filter",
                "TextProcessor.join"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "TextProcessor.process", predicate: "calls", target: "clean"),
                ExpectedRelationship(source: "TextProcessor.process", predicate: "calls", target: "tokenize"),
                ExpectedRelationship(source: "TextProcessor.process", predicate: "calls", target: "filter"),
                ExpectedRelationship(source: "TextProcessor.process", predicate: "calls", target: "join")
            ],
            minEvidenceCount: 4,
            requireSuccess: true
        )
    )

    /// Case 14: Repository pattern with CRUD.
    static let dataFlowRepository = BenchmarkCase(
        id: "df-02-repository",
        name: "Repository CRUD",
        description: "Validates entity extraction for repository pattern with full CRUD",
        category: .moduleContext,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Item.swift",
                content: """
                import Foundation

                struct Item {
                    let id: String
                    let name: String
                    var quantity: Int
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "ItemRepository.swift",
                content: """
                import Foundation

                class ItemRepository {
                    private var items: [String: Item] = [:]

                    func create(_ item: Item) {
                        items[item.id] = item
                    }

                    func read(_ id: String) -> Item? {
                        return items[id]
                    }

                    func update(_ item: Item) {
                        items[item.id] = item
                    }

                    func delete(_ id: String) {
                        items.removeValue(forKey: id)
                    }

                    func listAll() -> [Item] {
                        return Array(items.values)
                    }
                }
                """
            )
        ],
        queryEntity: "ItemRepository",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "ItemRepository",
                "Item",
                "ItemRepository.create",
                "ItemRepository.read",
                "ItemRepository.update",
                "ItemRepository.delete",
                "ItemRepository.listAll"
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    /// Case 15: Python data processing with functions.
    static let dataFlowPythonTransform = BenchmarkCase(
        id: "df-03-python-transform",
        name: "Python Data Transform",
        description: "Validates TreeSitter entity extraction for Python data processing",
        category: .moduleContext,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "transform.py",
                content: """
                class DataTransformer:
                    def __init__(self, config):
                        self.config = config
                        self.steps = []

                    def add_step(self, step_fn):
                        self.steps.append(step_fn)

                    def execute(self, data):
                        result = data
                        for step in self.steps:
                            result = step(result)
                        return result

                    def reset(self):
                        self.steps = []
                """
            )
        ],
        queryEntity: "DataTransformer",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "DataTransformer",
                "DataTransformer.__init__",
                "DataTransformer.add_step",
                "DataTransformer.execute",
                "DataTransformer.reset"
            ],
            minEvidenceCount: 2,
            requireSuccess: true
        )
    )

    // MARK: - Dependency Injection

    /// Case 16: Protocol-based dependency injection.
    static let diProtocolAbstraction = BenchmarkCase(
        id: "di-01-protocol-abstraction",
        name: "Protocol-Based DI",
        description: "Validates protocol abstraction pattern for dependency injection",
        category: .contextAssembly,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Cache.swift",
                content: """
                import Foundation

                protocol CacheProtocol {
                    func get(_ key: String) -> String?
                    func set(_ key: String, value: String)
                    func clear()
                }

                class InMemoryCache: CacheProtocol {
                    private var store: [String: String] = [:]

                    func get(_ key: String) -> String? {
                        return store[key]
                    }

                    func set(_ key: String, value: String) {
                        store[key] = value
                    }

                    func clear() {
                        store.removeAll()
                    }
                }

                class DiskCache: CacheProtocol {
                    let directory: String

                    init(directory: String) {
                        self.directory = directory
                    }

                    func get(_ key: String) -> String? {
                        return nil // simplified
                    }

                    func set(_ key: String, value: String) {
                        // write to disk
                    }

                    func clear() {
                        // remove files
                    }
                }
                """
            )
        ],
        queryEntity: "CacheProtocol",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "CacheProtocol",
                "InMemoryCache",
                "DiskCache",
                "CacheProtocol.get",
                "CacheProtocol.set",
                "CacheProtocol.clear"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "InMemoryCache", predicate: "conformsTo", target: "CacheProtocol"),
                ExpectedRelationship(source: "DiskCache", predicate: "conformsTo", target: "CacheProtocol")
            ],
            minEvidenceCount: 4,
            requireSuccess: true
        )
    )

    /// Case 17: Service layer depending on repository via protocol.
    static let diServiceLayer = BenchmarkCase(
        id: "di-02-service-layer",
        name: "Service Layer DI",
        description: "Validates multi-type dependency injection with protocol + service + impl",
        category: .contextAssembly,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "DataSource.swift",
                content: """
                import Foundation

                protocol DataSource {
                    func fetchItems() -> [String]
                    func saveItem(_ item: String)
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "LocalDataSource.swift",
                content: """
                import Foundation

                class LocalDataSource: DataSource {
                    private var items: [String] = []

                    func fetchItems() -> [String] {
                        return items
                    }

                    func saveItem(_ item: String) {
                        items.append(item)
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "ItemService.swift",
                content: """
                import Foundation

                class ItemService {
                    let dataSource: DataSource

                    init(dataSource: DataSource) {
                        self.dataSource = dataSource
                    }

                    func getAllItems() -> [String] {
                        return dataSource.fetchItems()
                    }

                    func addItem(_ item: String) {
                        dataSource.saveItem(item)
                    }
                }
                """
            )
        ],
        queryEntity: "ItemService",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "ItemService",
                "DataSource",
                "LocalDataSource",
                "ItemService.getAllItems",
                "ItemService.addItem"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "LocalDataSource", predicate: "conformsTo", target: "DataSource")
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    // MARK: - Architecture

    /// Case 18: MVVM-style architecture across files.
    static let architectureMVVM = BenchmarkCase(
        id: "arch-01-mvvm",
        name: "MVVM Architecture",
        description: "Validates entity discovery across model, view model, and view layers",
        category: .contextAssembly,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Task.swift",
                content: """
                import Foundation

                struct Task {
                    let id: String
                    let title: String
                    var isComplete: Bool
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "TaskViewModel.swift",
                content: """
                import Foundation

                class TaskViewModel {
                    private var tasks: [Task] = []
                    var displayTasks: [Task] { return tasks }

                    func addTask(title: String) {
                        let task = Task(id: UUID().uuidString, title: title, isComplete: false)
                        tasks.append(task)
                    }

                    func toggleTask(id: String) {
                        if let index = tasks.firstIndex(where: { $0.id == id }) {
                            tasks[index].isComplete.toggle()
                        }
                    }

                    func removeCompleted() {
                        tasks.removeAll { $0.isComplete }
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "TaskListView.swift",
                content: """
                import Foundation

                class TaskListView {
                    let viewModel: TaskViewModel

                    init(viewModel: TaskViewModel) {
                        self.viewModel = viewModel
                    }

                    func render() -> String {
                        let items = viewModel.displayTasks.map { task in
                            let check = task.isComplete ? "[x]" : "[ ]"
                            return "\\(check) \\(task.title)"
                        }
                        return items.joined(separator: "\\n")
                    }
                }
                """
            )
        ],
        queryEntity: "TaskViewModel",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Task",
                "TaskViewModel",
                "TaskListView",
                "TaskViewModel.addTask",
                "TaskViewModel.toggleTask",
                "TaskViewModel.removeCompleted"
            ],
            minEvidenceCount: 4,
            requireSuccess: true
        )
    )

    /// Case 19: Coordinator pattern — parent managing children.
    static let architectureCoordinator = BenchmarkCase(
        id: "arch-02-coordinator",
        name: "Coordinator Pattern",
        description: "Validates entity/relationship extraction for coordinator hierarchy",
        category: .contextAssembly,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Coordinator.swift",
                content: """
                import Foundation

                protocol Coordinator {
                    func start()
                    func stop()
                }

                class AppCoordinator: Coordinator {
                    private var children: [Coordinator] = []

                    func start() {
                        let auth = AuthCoordinator()
                        addChild(auth)
                        auth.start()
                    }

                    func stop() {
                        children.forEach { $0.stop() }
                        children.removeAll()
                    }

                    func addChild(_ coordinator: Coordinator) {
                        children.append(coordinator)
                    }

                    func removeChild(_ coordinator: Coordinator) {
                        // remove by identity
                    }
                }

                class AuthCoordinator: Coordinator {
                    func start() {
                        // show login
                    }

                    func stop() {
                        // cleanup
                    }

                    func showLogin() {
                        // present login screen
                    }
                }
                """
            )
        ],
        queryEntity: "AppCoordinator",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Coordinator",
                "AppCoordinator",
                "AuthCoordinator",
                "AppCoordinator.start",
                "AppCoordinator.stop",
                "AppCoordinator.addChild"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "AppCoordinator", predicate: "conformsTo", target: "Coordinator"),
                ExpectedRelationship(source: "AuthCoordinator", predicate: "conformsTo", target: "Coordinator")
            ],
            minEvidenceCount: 4,
            requireSuccess: true
        )
    )

    // MARK: - Edge Cases

    /// Case 20: Near-empty file with just a struct.
    static let edgeCaseEmptyStruct = BenchmarkCase(
        id: "edge-01-empty-struct",
        name: "Empty Struct",
        description: "Validates pipeline handles minimal input without failure",
        category: .edgeCase,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Empty.swift",
                content: """
                struct Marker {}
                """
            )
        ],
        queryEntity: "Marker",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: ["Marker"],
            expectedPredicates: ["kind"],
            minEvidenceCount: 1,
            requireSuccess: true
        )
    )

    /// Case 21: Single top-level function, no type wrapper.
    static let edgeCaseSingleFunction = BenchmarkCase(
        id: "edge-02-single-function",
        name: "Single Top-Level Function",
        description: "Validates pipeline handles a file with only a free function",
        category: .edgeCase,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Helpers.swift",
                content: """
                import Foundation

                func greet(name: String) -> String {
                    return "Hello, \\(name)!"
                }
                """
            )
        ],
        queryEntity: "greet",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: ["greet"],
            expectedPredicates: ["kind", "signature"],
            minEvidenceCount: 1,
            requireSuccess: true
        )
    )

    /// Case 22: Deeply nested types — 3 levels of nesting.
    static let edgeCaseDeeplyNested = BenchmarkCase(
        id: "edge-03-deeply-nested",
        name: "Deeply Nested Types",
        description: "Validates pipeline handles multiple nesting levels",
        category: .edgeCase,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Theme.swift",
                content: """
                import Foundation

                struct Theme {
                    struct Colors {
                        struct Primary {
                            let main: String
                            let accent: String
                        }

                        let primary: Primary
                        let background: String
                    }

                    struct Typography {
                        let headingSize: Int
                        let bodySize: Int
                    }

                    let colors: Colors
                    let typography: Typography

                    static func defaultTheme() -> Theme {
                        return Theme(
                            colors: Colors(
                                primary: Colors.Primary(main: "#000", accent: "#333"),
                                background: "#FFF"
                            ),
                            typography: Typography(headingSize: 24, bodySize: 16)
                        )
                    }
                }
                """
            )
        ],
        queryEntity: "Theme",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Theme",
                "Theme.Colors",
                "Theme.Typography",
                "Theme.colors",
                "Theme.typography",
                "Theme.defaultTheme"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "Theme", predicate: "owns", target: "Colors"),
                ExpectedRelationship(source: "Theme", predicate: "owns", target: "Typography")
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )
}
