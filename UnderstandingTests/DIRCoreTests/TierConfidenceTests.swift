// TierConfidenceTests.swift — DIRCoreTests
// IAG-004 §3.4: Tier-confidence bounds validation
// DAS-003 I2: T0 requires deterministic; T1/T2 forbid deterministic

import Testing
@testable import DIRCore

@Suite("Tier-Confidence Bounds")
struct TierConfidenceTests {

    @Test("T0 requires deterministic confidence")
    func t0RequiresDeterministic() {
        #expect(Confidence.deterministic.isValid(for: .t0))
        #expect(!Confidence.high.isValid(for: .t0))
        #expect(!Confidence.moderate.isValid(for: .t0))
        #expect(!Confidence.low.isValid(for: .t0))
    }

    @Test("T1 forbids deterministic confidence")
    func t1ForbidsDeterministic() {
        #expect(!Confidence.deterministic.isValid(for: .t1))
        #expect(Confidence.high.isValid(for: .t1))
        #expect(Confidence.moderate.isValid(for: .t1))
        #expect(Confidence.low.isValid(for: .t1))
    }

    @Test("T2 forbids deterministic confidence")
    func t2ForbidsDeterministic() {
        #expect(!Confidence.deterministic.isValid(for: .t2))
        #expect(Confidence.high.isValid(for: .t2))
        #expect(Confidence.moderate.isValid(for: .t2))
        #expect(Confidence.low.isValid(for: .t2))
    }

    @Test("Tier ordering: T0 < T1 < T2")
    func tierOrdering() {
        #expect(Tier.t0 < Tier.t1)
        #expect(Tier.t1 < Tier.t2)
        #expect(Tier.t0 < Tier.t2)
    }

    @Test("Confidence ordering: low < moderate < high < deterministic")
    func confidenceOrdering() {
        #expect(Confidence.low < Confidence.moderate)
        #expect(Confidence.moderate < Confidence.high)
        #expect(Confidence.high < Confidence.deterministic)
    }

    @Test("All tiers enumerated")
    func allTiers() {
        #expect(Tier.allCases == [.t0, .t1, .t2])
    }

    @Test("All confidence levels enumerated")
    func allConfidenceLevels() {
        #expect(Confidence.allCases == [.deterministic, .high, .moderate, .low])
    }
}
