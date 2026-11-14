import Foundation
import Testing
@testable import SortlyCore

@Suite("Preview photos")
struct PreviewPickerTests {
    let ids: [AssetID] = (0..<40).map { AssetID(String(format: "p%02d", $0)) }
    var dates: [AssetID: Date] {
        // Ids and dates run in opposite directions, so sorting by id would be wrong.
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, Date(timeIntervalSince1970: Double(1000 - $0) * 3600)) })
    }

    @Test func spreadsOverTheWholeTimeSpanOldestFirst() {
        let picked = PreviewPicker.pick(Set(ids), dates: dates, cover: nil, count: 8)
        #expect(picked.count == 8)
        #expect(picked.first == "p39") // oldest
        #expect(picked.last == "p00")  // newest
        let times = picked.compactMap { dates[$0] }
        #expect(times == times.sorted())
    }

    @Test func coverIsAlwaysShown() {
        let picked = PreviewPicker.pick(Set(ids), dates: dates, cover: "p17", count: 8)
        #expect(picked.contains("p17"))
        #expect(picked.count == 8)
        #expect(Set(picked).count == 8)
        #expect(picked.compactMap { dates[$0] } == picked.compactMap { dates[$0] }.sorted())
    }

    @Test func smallSetsAndUndatedPhotos() {
        var d = dates
        d["p01"] = nil
        let few = PreviewPicker.pick(["p01", "p02", "p03"], dates: d, cover: nil, count: 8)
        #expect(few == ["p03", "p02", "p01"]) // undated last
        #expect(PreviewPicker.pick(Set(ids), dates: d, cover: nil, count: 1).count == 1)
    }
}
