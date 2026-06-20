import XCTest
@testable import Decode

/// Tests for ``TreeSitterParser`` entity extraction across all supported languages.
///
/// Each test verifies that the parser correctly extracts the expected entity
/// types and names from representative source code snippets.
final class TreeSitterParserTests: XCTestCase {

    private let parser = TreeSitterParser()

    // MARK: - Python

    func testPythonExtraction() {
        let source = """
        def greet(name):
            return f"Hello, {name}!"

        class UserService:
            def __init__(self, db):
                self.db = db

            def find_user(self, user_id):
                return self.db.get(user_id)

        @staticmethod
        def helper():
            pass
        """

        let entities = parser.parseDetailed(source: source, fileName: "service.py")

        XCTAssertFalse(entities.isEmpty, "Python: should extract entities")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("greet"), "Python: should find greet function")
        XCTAssertTrue(names.contains("UserService"), "Python: should find UserService class")
        XCTAssertTrue(names.contains("__init__"), "Python: should find __init__ method")
        XCTAssertTrue(names.contains("find_user"), "Python: should find find_user method")

        // Verify class is typed correctly.
        let userService = entities.first { $0.entity.name == "UserService" }
        XCTAssertEqual(userService?.entity.entityType, .class)

        // Verify top-level function typed correctly.
        let greet = entities.first { $0.entity.name == "greet" }
        XCTAssertEqual(greet?.entity.entityType, .function)
    }

    // MARK: - JavaScript

    func testJavaScriptExtraction() {
        let source = """
        function fetchData(url) {
            return fetch(url);
        }

        class ApiClient {
            constructor(baseUrl) {
                this.baseUrl = baseUrl;
            }

            async get(path) {
                return fetch(this.baseUrl + path);
            }
        }

        const UserCard = ({ name, email }) => {
            return <div>{name}</div>;
        };

        const useAuth = () => {
            const [user, setUser] = useState(null);
            return { user };
        };
        """

        let entities = parser.parseDetailed(source: source, fileName: "api.js")

        XCTAssertFalse(entities.isEmpty, "JS: should extract entities")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("fetchData"), "JS: should find fetchData")
        XCTAssertTrue(names.contains("ApiClient"), "JS: should find ApiClient class")
        XCTAssertTrue(names.contains("UserCard"), "JS: should find UserCard component")
        XCTAssertTrue(names.contains("useAuth"), "JS: should find useAuth hook")
    }

    // MARK: - TypeScript

    func testTypeScriptExtraction() {
        let source = """
        interface UserRepository {
            findById(id: string): Promise<User>;
            save(user: User): Promise<void>;
        }

        class UserService implements UserRepository {
            async findById(id: string): Promise<User> {
                return this.db.get(id);
            }

            async save(user: User): Promise<void> {
                await this.db.put(user);
            }
        }

        enum Status {
            Active = "active",
            Inactive = "inactive",
        }

        type Config = {
            host: string;
            port: number;
        };

        const UserProfile = ({ user }: Props) => {
            return <div>{user.name}</div>;
        };

        const useTheme = () => {
            return useContext(ThemeContext);
        };
        """

        let entities = parser.parseDetailed(source: source, fileName: "user.ts")

        XCTAssertFalse(entities.isEmpty, "TS: should extract entities")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("UserRepository"), "TS: should find interface")
        XCTAssertTrue(names.contains("UserService"), "TS: should find class")
        XCTAssertTrue(names.contains("Status"), "TS: should find enum")
        XCTAssertTrue(names.contains("Config"), "TS: should find type alias")
    }

    // MARK: - Java

    func testJavaExtraction() {
        let source = """
        public interface Comparable<T> {
            int compareTo(T other);
        }

        public class ArrayList<E> implements Comparable<ArrayList<E>> {
            private Object[] data;

            public ArrayList() {
                this.data = new Object[10];
            }

            public void add(E element) {
                // ...
            }

            public int compareTo(ArrayList<E> other) {
                return this.size() - other.size();
            }
        }

        public enum Color {
            RED, GREEN, BLUE
        }
        """

        let entities = parser.parseDetailed(source: source, fileName: "ArrayList.java")

        XCTAssertFalse(entities.isEmpty, "Java: should extract entities")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("Comparable"), "Java: should find interface")
        XCTAssertTrue(names.contains("ArrayList"), "Java: should find class")
        XCTAssertTrue(names.contains("add"), "Java: should find method")
        XCTAssertTrue(names.contains("Color"), "Java: should find enum")

        let comparable = entities.first { $0.entity.name == "Comparable" }
        XCTAssertEqual(comparable?.entity.entityType, .protocol)
    }

    // MARK: - C#

    func testCSharpExtraction() {
        let source = """
        namespace MyApp.Services
        {
            public interface IUserService
            {
                Task<User> GetUser(int id);
            }

            public class UserService : IUserService
            {
                public UserService(IDbContext db)
                {
                    _db = db;
                }

                public async Task<User> GetUser(int id)
                {
                    return await _db.Users.FindAsync(id);
                }
            }

            public struct Point
            {
                public int X;
                public int Y;
            }
        }
        """

        let entities = parser.parseDetailed(source: source, fileName: "UserService.cs")

        XCTAssertFalse(entities.isEmpty, "C#: should extract entities")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("IUserService"), "C#: should find interface")
        XCTAssertTrue(names.contains("UserService"), "C#: should find class")
        XCTAssertTrue(names.contains("Point"), "C#: should find struct")

        let point = entities.first { $0.entity.name == "Point" }
        XCTAssertEqual(point?.entity.entityType, .struct)
    }

    // MARK: - C

    func testCExtraction() {
        let source = """
        typedef struct {
            int x;
            int y;
        } Point;

        struct LinkedList {
            int value;
            struct LinkedList* next;
        };

        void swap(int* a, int* b) {
            int temp = *a;
            *a = *b;
            *b = temp;
        }

        int binary_search(int arr[], int size, int target) {
            int low = 0, high = size - 1;
            while (low <= high) {
                int mid = (low + high) / 2;
                if (arr[mid] == target) return mid;
                if (arr[mid] < target) low = mid + 1;
                else high = mid - 1;
            }
            return -1;
        }
        """

        let entities = parser.parseDetailed(source: source, fileName: "search.c")

        XCTAssertFalse(entities.isEmpty, "C: should extract entities")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("swap"), "C: should find swap function")
        XCTAssertTrue(names.contains("binary_search"), "C: should find binary_search function")
        XCTAssertTrue(names.contains("LinkedList"), "C: should find struct")

        let linkedList = entities.first { $0.entity.name == "LinkedList" }
        XCTAssertEqual(linkedList?.entity.entityType, .struct)
    }

    // MARK: - C++

    func testCPPExtraction() {
        let source = """
        class Vector {
        public:
            Vector(int size) : data_(new int[size]), size_(size) {}

            int& operator[](int index) {
                return data_[index];
            }

            int size() const { return size_; }

        private:
            int* data_;
            int size_;
        };

        struct Config {
            std::string host;
            int port;
        };

        void quicksort(int arr[], int low, int high) {
            if (low < high) {
                int pivot = partition(arr, low, high);
                quicksort(arr, low, pivot - 1);
                quicksort(arr, pivot + 1, high);
            }
        }

        namespace utils {
            int clamp(int value, int min, int max) {
                if (value < min) return min;
                if (value > max) return max;
                return value;
            }
        }
        """

        let entities = parser.parseDetailed(source: source, fileName: "vector.cpp")

        XCTAssertFalse(entities.isEmpty, "C++: should extract entities")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("Vector"), "C++: should find class")
        XCTAssertTrue(names.contains("quicksort"), "C++: should find function")

        let vector = entities.first { $0.entity.name == "Vector" }
        XCTAssertEqual(vector?.entity.entityType, .class)
    }

    // MARK: - HTML

    func testHTMLExtraction() {
        let source = """
        <html>
        <head>
            <title>Test Page</title>
        </head>
        <body>
            <header>
                <nav>
                    <a href="/">Home</a>
                </nav>
            </header>
            <main>
                <section>
                    <article>
                        <h1>Article Title</h1>
                        <p>Content here.</p>
                    </article>
                </section>
            </main>
            <form action="/submit">
                <input type="text" name="email" />
            </form>
            <footer>
                <p>Footer content</p>
            </footer>
        </body>
        </html>
        """

        let entities = parser.parseDetailed(source: source, fileName: "page.html")

        XCTAssertFalse(entities.isEmpty, "HTML: should extract semantic elements")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("html"), "HTML: should find html")
        XCTAssertTrue(names.contains("nav"), "HTML: should find nav")
        XCTAssertTrue(names.contains("main"), "HTML: should find main")
        XCTAssertTrue(names.contains("form"), "HTML: should find form")
        XCTAssertTrue(names.contains("footer"), "HTML: should find footer")

        // Non-semantic elements like <a>, <p>, <h1> should be filtered out.
        XCTAssertFalse(names.contains("a"), "HTML: should filter non-semantic elements")
        XCTAssertFalse(names.contains("p"), "HTML: should filter non-semantic elements")
        XCTAssertFalse(names.contains("h1"), "HTML: should filter non-semantic elements")
    }

    // MARK: - CSS

    func testCSSExtraction() {
        let source = """
        body {
            margin: 0;
            font-family: sans-serif;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
        }

        #header nav a {
            color: white;
            text-decoration: none;
        }

        @media (max-width: 768px) {
            .container {
                padding: 0 16px;
            }
        }

        @keyframes fadeIn {
            from { opacity: 0; }
            to { opacity: 1; }
        }
        """

        let entities = parser.parseDetailed(source: source, fileName: "styles.css")

        XCTAssertFalse(entities.isEmpty, "CSS: should extract rule sets and at-rules")

        // Should have rule sets and @media and @keyframes.
        let types = Set(entities.map(\.entity.entityType))
        XCTAssertTrue(entities.count >= 4, "CSS: should find at least 4 entities (3 rules + @media + @keyframes)")
    }

    // MARK: - Parent Relationships

    func testParentChildRelationships() {
        let source = """
        class Animal:
            def __init__(self, name):
                self.name = name

            def speak(self):
                pass
        """

        let entities = parser.parseDetailed(source: source, fileName: "animal.py")
        let animal = entities.first { $0.entity.name == "Animal" }
        let init_ = entities.first { $0.entity.name == "__init__" }
        let speak = entities.first { $0.entity.name == "speak" }

        XCTAssertNotNil(animal, "Should find Animal class")
        XCTAssertNotNil(init_, "Should find __init__")
        XCTAssertNotNil(speak, "Should find speak")

        // Methods should have Animal as parent.
        XCTAssertEqual(init_?.parentStableId, animal?.entity.stableId, "__init__ should be child of Animal")
        XCTAssertEqual(speak?.parentStableId, animal?.entity.stableId, "speak should be child of Animal")

        // Methods inside a class should be typed as .method.
        XCTAssertEqual(init_?.entity.entityType, .method, "__init__ should be method type")
        XCTAssertEqual(speak?.entity.entityType, .method, "speak should be method type")
    }

    // MARK: - Unsupported Files

    func testUnsupportedFileReturnsEmpty() {
        let entities = parser.parseDetailed(
            source: "some content",
            fileName: "readme.md"
        )
        XCTAssertTrue(entities.isEmpty, "Unsupported files should return empty")
    }

    func testSwiftFileReturnsEmpty() {
        // Swift files should be handled by SwiftSyntaxParser, not TreeSitterParser.
        let entities = parser.parseDetailed(
            source: "struct Foo {}",
            fileName: "foo.swift"
        )
        XCTAssertTrue(entities.isEmpty, "Swift files should return empty from TreeSitterParser")
    }
}
