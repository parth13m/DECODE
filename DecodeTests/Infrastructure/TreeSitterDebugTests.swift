import XCTest
import SwiftTreeSitter
import TreeSitterCPP
@testable import Decode

/// Debug tests for tree-sitter parsing. Not intended for CI.
final class TreeSitterDebugTests: XCTestCase {

    func testCPPParseTree() {
        let parser = TreeSitterParser()
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
                int pivot = 0;
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
        XCTAssertFalse(entities.isEmpty, "C++ entities should not be empty")

        let names = entities.map(\.entity.name)
        XCTAssertTrue(names.contains("Vector"), "Should find Vector class")
        XCTAssertTrue(names.contains("quicksort"), "Should find quicksort function")
        XCTAssertTrue(names.contains("utils"), "Should find utils namespace")
    }
}
