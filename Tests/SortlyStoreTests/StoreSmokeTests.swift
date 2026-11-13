import Testing
@testable import SortlyStore

@Suite("Store smoke")
struct StoreSmokeTests {
    @Test func moduleLoads() { #expect(true) }
}
