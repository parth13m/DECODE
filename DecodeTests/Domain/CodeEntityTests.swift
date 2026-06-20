import Foundation
import Testing
@testable import Decode

/// Tests for the CodeEntity domain model and EntityType enum.
struct CodeEntityTests {

    @Test func entityTypeCoversAllCases() {
        let allCases = EntityType.allCases
        #expect(allCases.contains(.function))
        #expect(allCases.contains(.class))
        #expect(allCases.contains(.method))
        #expect(allCases.contains(.struct))
        #expect(allCases.contains(.protocol))
        #expect(allCases.contains(.enum))
        #expect(allCases.contains(.component))
        #expect(allCases.contains(.hook))
    }

    @Test func entityTypeCodableRoundTrip() throws {
        for entityType in EntityType.allCases {
            let data = try JSONEncoder().encode(entityType)
            let decoded = try JSONDecoder().decode(EntityType.self, from: data)
            #expect(decoded == entityType)
        }
    }
}
