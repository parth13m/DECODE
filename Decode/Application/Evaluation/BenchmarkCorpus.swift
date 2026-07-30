// BenchmarkCorpus.swift — Decode Application
// E1-01: Canonical Benchmark Corpus — 30 cases that permanently measure
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
/// let cases = BenchmarkCorpus.allCases          // all 30 cases
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

        // Data Flow / Module Context (7 cases)
        dataFlowPipeline,
        dataFlowRepository,
        dataFlowPythonTransform,
        moduleMultiFileService,
        moduleProtocolConformanceAcrossFiles,
        moduleLayeredArchitecture,
        moduleSingleFileSuppression,

        // Dependency Injection / Architecture (4 cases)
        diProtocolAbstraction,
        diServiceLayer,
        architectureMVVM,
        architectureCoordinator,

        // Question-Aware Scope Selection (4 cases, E3-01)
        questionImpactCallers,
        questionDependencyChain,
        questionOverviewArchitecture,
        questionNarrowSimple,

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

    // MARK: - Module Context (E2-00)

    /// Case 23: Multi-file service module — validates module entity creation
    /// and cross-file entity discovery within a module directory.
    static let moduleMultiFileService = BenchmarkCase(
        id: "mod-01-multi-file-service",
        name: "Multi-File Service Module",
        description: "Validates module boundary detection and entity discovery across a service module with multiple files in the same directory",
        category: .moduleContext,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "UserModel.swift",
                content: """
                import Foundation

                struct UserModel {
                    let id: String
                    let name: String
                    let email: String

                    func displayName() -> String {
                        return name.isEmpty ? email : name
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "UserRepository.swift",
                content: """
                import Foundation

                class UserRepository {
                    private var users: [String: UserModel] = [:]

                    func save(_ user: UserModel) {
                        users[user.id] = user
                    }

                    func findById(_ id: String) -> UserModel? {
                        return users[id]
                    }

                    func findAll() -> [UserModel] {
                        return Array(users.values)
                    }

                    func delete(_ id: String) {
                        users.removeValue(forKey: id)
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "UserService.swift",
                content: """
                import Foundation

                class UserService {
                    let repository: UserRepository

                    init(repository: UserRepository) {
                        self.repository = repository
                    }

                    func createUser(name: String, email: String) -> UserModel {
                        let user = UserModel(id: UUID().uuidString, name: name, email: email)
                        repository.save(user)
                        return user
                    }

                    func getUser(_ id: String) -> UserModel? {
                        return repository.findById(id)
                    }

                    func listUsers() -> [UserModel] {
                        return repository.findAll()
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
                "UserRepository",
                "UserModel",
                "UserService.createUser",
                "UserService.getUser",
                "UserService.listUsers",
                "UserRepository.save",
                "UserRepository.findById"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "UserService.createUser", predicate: "calls", target: "save"),
                ExpectedRelationship(source: "UserService.getUser", predicate: "calls", target: "findById")
            ],
            minEvidenceCount: 5,
            expectedStages: Set(["direct"]),
            expectedTiers: Set(["t0"]),
            requireSuccess: true
        )
    )

    /// Case 24: Protocol conformance across files in a module — validates
    /// cross-file relationship resolution within module boundaries.
    static let moduleProtocolConformanceAcrossFiles = BenchmarkCase(
        id: "mod-02-protocol-across-files",
        name: "Module Protocol Conformance",
        description: "Validates cross-file conformsTo resolution and module-level entity grouping",
        category: .moduleContext,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Persistable.swift",
                content: """
                import Foundation

                protocol Persistable {
                    var identifier: String { get }
                    func toDictionary() -> [String: Any]
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "Document.swift",
                content: """
                import Foundation

                class Document: Persistable {
                    let identifier: String
                    let title: String
                    let content: String
                    let createdAt: Date

                    init(identifier: String, title: String, content: String) {
                        self.identifier = identifier
                        self.title = title
                        self.content = content
                        self.createdAt = Date()
                    }

                    func toDictionary() -> [String: Any] {
                        return [
                            "id": identifier,
                            "title": title,
                            "content": content
                        ]
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "Settings.swift",
                content: """
                import Foundation

                struct Settings: Persistable {
                    let identifier: String
                    let theme: String
                    let fontSize: Int

                    func toDictionary() -> [String: Any] {
                        return [
                            "id": identifier,
                            "theme": theme,
                            "fontSize": fontSize
                        ]
                    }
                }
                """
            )
        ],
        queryEntity: "Document",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Persistable",
                "Document",
                "Settings",
                "Document.identifier",
                "Document.title",
                "Document.content",
                "Document.toDictionary"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "Document", predicate: "conformsTo", target: "Persistable"),
                ExpectedRelationship(source: "Settings", predicate: "conformsTo", target: "Persistable")
            ],
            minEvidenceCount: 4,
            requireSuccess: true
        )
    )

    /// Case 25: Layered architecture — validates module boundary detection
    /// across multiple directories simulating architectural layers.
    static let moduleLayeredArchitecture = BenchmarkCase(
        id: "mod-03-layered-architecture",
        name: "Layered Architecture Module",
        description: "Validates entity discovery and relationships in a multi-layer architecture pattern",
        category: .moduleContext,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Event.swift",
                content: """
                import Foundation

                struct Event {
                    let id: String
                    let name: String
                    let date: Date
                    let capacity: Int
                    var attendees: [String]

                    var isFull: Bool {
                        return attendees.count >= capacity
                    }

                    mutating func addAttendee(_ name: String) -> Bool {
                        guard !isFull else { return false }
                        attendees.append(name)
                        return true
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "EventStore.swift",
                content: """
                import Foundation

                class EventStore {
                    private var events: [String: Event] = [:]

                    func save(_ event: Event) {
                        events[event.id] = event
                    }

                    func find(_ id: String) -> Event? {
                        return events[id]
                    }

                    func upcoming() -> [Event] {
                        let now = Date()
                        return events.values.filter { $0.date > now }
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "EventCoordinator.swift",
                content: """
                import Foundation

                class EventCoordinator {
                    let store: EventStore

                    init(store: EventStore) {
                        self.store = store
                    }

                    func createEvent(name: String, date: Date, capacity: Int) -> Event {
                        let event = Event(
                            id: UUID().uuidString,
                            name: name,
                            date: date,
                            capacity: capacity,
                            attendees: []
                        )
                        store.save(event)
                        return event
                    }

                    func registerAttendee(_ name: String, eventId: String) -> Bool {
                        guard var event = store.find(eventId) else { return false }
                        let added = event.addAttendee(name)
                        if added { store.save(event) }
                        return added
                    }

                    func upcomingEvents() -> [Event] {
                        return store.upcoming()
                    }
                }
                """
            )
        ],
        queryEntity: "EventCoordinator",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Event",
                "EventStore",
                "EventCoordinator",
                "EventCoordinator.createEvent",
                "EventCoordinator.registerAttendee",
                "EventCoordinator.upcomingEvents",
                "EventStore.save",
                "EventStore.find"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "EventCoordinator.createEvent", predicate: "calls", target: "save"),
                ExpectedRelationship(source: "EventCoordinator.registerAttendee", predicate: "calls", target: "find"),
                ExpectedRelationship(source: "EventCoordinator.registerAttendee", predicate: "calls", target: "addAttendee")
            ],
            minEvidenceCount: 5,
            requireSuccess: true
        )
    )

    /// Case 26: Single-file module — validates that single-file modules
    /// do not produce unnecessary module context noise.
    static let moduleSingleFileSuppression = BenchmarkCase(
        id: "mod-04-single-file-suppression",
        name: "Single-File Module Suppression",
        description: "Validates that a single-file directory produces no module noise in output",
        category: .moduleContext,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Constants.swift",
                content: """
                import Foundation

                enum Constants {
                    static let appName = "Decode"
                    static let version = "1.0.0"
                    static let maxRetries = 3
                    static let timeoutInterval: TimeInterval = 30.0

                    enum API {
                        static let baseURL = "https://api.example.com"
                        static let apiVersion = "v1"
                    }

                    enum UI {
                        static let cornerRadius: Double = 8.0
                        static let defaultPadding: Double = 16.0
                    }
                }
                """
            )
        ],
        queryEntity: "Constants",
        purpose: "explain",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Constants",
                "Constants.API",
                "Constants.UI"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "Constants", predicate: "owns", target: "API"),
                ExpectedRelationship(source: "Constants", predicate: "owns", target: "UI")
            ],
            minEvidenceCount: 2,
            requireSuccess: true
        )
    )

    // MARK: - Question-Aware Scope Selection (E3-01)

    /// Case 27: Impact question — "who calls this?" on a method with known callers.
    /// Validates that .impact intent uses inverse traversal to find callers.
    /// With .explain intent, only forward callees are found.
    /// With .impact intent, reverse callers should also appear in evidence.
    static let questionImpactCallers = BenchmarkCase(
        id: "qa-01-impact-callers",
        name: "Impact: Who Calls This",
        description: "Validates impact intent finds callers via inverse traversal",
        category: .contextAssembly,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Validator.swift",
                content: """
                import Foundation

                class Validator {
                    func validate(_ input: String) -> Bool {
                        return !input.isEmpty && input.count < 1000
                    }

                    func sanitize(_ input: String) -> String {
                        return input.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "FormHandler.swift",
                content: """
                import Foundation

                class FormHandler {
                    let validator: Validator

                    init(validator: Validator) {
                        self.validator = validator
                    }

                    func submit(name: String, email: String) -> Bool {
                        let cleanName = validator.sanitize(name)
                        let cleanEmail = validator.sanitize(email)
                        guard validator.validate(cleanName) else { return false }
                        guard validator.validate(cleanEmail) else { return false }
                        return true
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "APIEndpoint.swift",
                content: """
                import Foundation

                class APIEndpoint {
                    let formHandler: FormHandler

                    init(formHandler: FormHandler) {
                        self.formHandler = formHandler
                    }

                    func handleRequest(name: String, email: String) -> String {
                        if formHandler.submit(name: name, email: email) {
                            return "success"
                        }
                        return "validation_failed"
                    }
                }
                """
            )
        ],
        queryEntity: "Validator",
        purpose: "followup",
        questionHint: "who calls this validator? what uses validate?",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Validator",
                "Validator.validate",
                "Validator.sanitize",
                "FormHandler",
                "FormHandler.submit"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "FormHandler.submit", predicate: "calls", target: "validate"),
                ExpectedRelationship(source: "FormHandler.submit", predicate: "calls", target: "sanitize")
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    /// Case 28: Dependency question — "what does this depend on?"
    /// Validates that .dependencies intent uses forward traversal with depth 2,
    /// discovering transitive dependencies.
    static let questionDependencyChain = BenchmarkCase(
        id: "qa-02-dependency-chain",
        name: "Dependencies: What Does This Depend On",
        description: "Validates dependency intent discovers transitive call chains at depth 2",
        category: .contextAssembly,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Encoder.swift",
                content: """
                import Foundation

                class Encoder {
                    func encode(_ data: String) -> String {
                        return compress(data)
                    }

                    func compress(_ input: String) -> String {
                        return input.replacingOccurrences(of: " ", with: "")
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "Serializer.swift",
                content: """
                import Foundation

                class Serializer {
                    let encoder: Encoder

                    init(encoder: Encoder) {
                        self.encoder = encoder
                    }

                    func serialize(_ object: String) -> String {
                        let encoded = encoder.encode(object)
                        return wrap(encoded)
                    }

                    func wrap(_ content: String) -> String {
                        return "{\\(content)}"
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "Exporter.swift",
                content: """
                import Foundation

                class Exporter {
                    let serializer: Serializer

                    init(serializer: Serializer) {
                        self.serializer = serializer
                    }

                    func export(_ data: String) -> String {
                        let result = serializer.serialize(data)
                        return format(result)
                    }

                    func format(_ output: String) -> String {
                        return "EXPORT: \\(output)"
                    }
                }
                """
            )
        ],
        queryEntity: "Exporter",
        purpose: "followup",
        questionHint: "what does this depend on? what does exporter call?",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Exporter",
                "Exporter.export",
                "Exporter.format",
                "Serializer",
                "Serializer.serialize"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "Exporter.export", predicate: "calls", target: "serialize"),
                ExpectedRelationship(source: "Exporter.export", predicate: "calls", target: "format")
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    /// Case 29: Overview question — "how does this fit in the architecture?"
    /// Validates that .overview intent uses balanced shallow traversal with
    /// both forward and inverse directions.
    static let questionOverviewArchitecture = BenchmarkCase(
        id: "qa-03-overview-architecture",
        name: "Overview: How Does This Fit",
        description: "Validates overview intent gathers balanced evidence from both directions",
        category: .contextAssembly,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "MessageBus.swift",
                content: """
                import Foundation

                protocol MessageHandler {
                    func handle(_ message: String)
                }

                class MessageBus {
                    private var handlers: [MessageHandler] = []

                    func register(_ handler: MessageHandler) {
                        handlers.append(handler)
                    }

                    func publish(_ message: String) {
                        for handler in handlers {
                            handler.handle(message)
                        }
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "NotificationService.swift",
                content: """
                import Foundation

                class NotificationService: MessageHandler {
                    func handle(_ message: String) {
                        sendNotification(message)
                    }

                    func sendNotification(_ text: String) {
                        // push notification
                    }
                }
                """
            ),
            BenchmarkSourceFile(
                fileName: "AppBootstrap.swift",
                content: """
                import Foundation

                class AppBootstrap {
                    let bus: MessageBus

                    init() {
                        self.bus = MessageBus()
                    }

                    func configure() {
                        let notifier = NotificationService()
                        bus.register(notifier)
                    }

                    func start() {
                        configure()
                        bus.publish("app_started")
                    }
                }
                """
            )
        ],
        queryEntity: "MessageBus",
        purpose: "followup",
        questionHint: "how does this fit in the architecture? overview of message bus role",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "MessageBus",
                "MessageHandler",
                "MessageBus.register",
                "MessageBus.publish",
                "NotificationService"
            ],
            expectedRelationships: [
                ExpectedRelationship(source: "NotificationService", predicate: "conformsTo", target: "MessageHandler")
            ],
            minEvidenceCount: 3,
            requireSuccess: true
        )
    )

    /// Case 30: Narrow question — "what does this line do?"
    /// Validates that narrow intent uses local scope for simple, focused questions.
    static let questionNarrowSimple = BenchmarkCase(
        id: "qa-04-narrow-simple",
        name: "Narrow: What Does This Do",
        description: "Validates narrow classification uses local scope for focused questions",
        category: .contextAssembly,
        sourceFiles: [
            BenchmarkSourceFile(
                fileName: "Calculator.swift",
                content: """
                import Foundation

                class Calculator {
                    func add(_ a: Int, _ b: Int) -> Int {
                        return a + b
                    }

                    func subtract(_ a: Int, _ b: Int) -> Int {
                        return a - b
                    }

                    func multiply(_ a: Int, _ b: Int) -> Int {
                        return a * b
                    }

                    func divide(_ a: Int, _ b: Int) -> Int? {
                        guard b != 0 else { return nil }
                        return a / b
                    }
                }
                """
            )
        ],
        queryEntity: "Calculator",
        purpose: "followup",
        questionHint: "what does this do? just this simple calculator",
        expectations: BenchmarkExpectations(
            expectedEntities: [
                "Calculator",
                "Calculator.add",
                "Calculator.subtract",
                "Calculator.multiply",
                "Calculator.divide"
            ],
            minEvidenceCount: 2,
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
