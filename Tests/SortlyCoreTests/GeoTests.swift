import Foundation
import Testing
@testable import SortlyCore
import SortlyTestSupport

@Suite("Geography")
struct GeoTests {
    @Test func haversineDistanceMunichRome() {
        let d = GeoMath.distance(Fixture.Places.munichHome, Fixture.Places.rome)
        #expect(abs(d - 698_000) < 10_000) // ≈ 698 km great-circle
    }

    @Test func centroidAcrossAntimeridian() throws {
        let c = try #require(GeoMath.centroid([
            GeoCoordinate(latitude: 0, longitude: 179.5),
            GeoCoordinate(latitude: 0, longitude: -179.5),
        ]))
        #expect(abs(abs(c.longitude) - 180) < 0.01)
    }

    @Test func implausibleCoordinatesAreIgnored() {
        #expect(!GeoCoordinate(latitude: 0, longitude: 0).isPlausible)
        #expect(!GeoCoordinate(latitude: 91, longitude: 0).isPlausible)
        let asset = AssetSnapshot(id: "a", location: GeoCoordinate(latitude: 48, longitude: 11), locationAccuracy: 20_000)
        #expect(asset.usableLocation == nil)
    }

    @Test func spatialIndexFindsAllNeighboursIncludingAcrossCells() {
        var points: [(GeoCoordinate, Int)] = []
        for i in 0..<400 {
            let lat = 47.9 + Double(i % 20) * 0.0012
            let lon = 11.4 + Double(i / 20) * 0.0017
            points.append((GeoCoordinate(latitude: lat, longitude: lon), i))
        }
        let index = GeoSpatialIndex(cellSize: 200, points: points)
        for probe in stride(from: 0, to: 400, by: 37) {
            let center = points[probe].0
            let expected = Set(points.filter { GeoMath.distance($0.0, center) <= 200 }.map(\.1))
            let actual = Set(index.query(near: center, radius: 200).map(\.element))
            #expect(expected == actual)
        }
    }

    @Test func dbscanSeparatesTwoDenseAreasAndNoise() {
        var coords: [GeoCoordinate] = []
        for i in 0..<30 { coords.append(Fixture.jitter(Fixture.Places.munichHome, seed: i, meters: 80)) }
        for i in 0..<20 { coords.append(Fixture.jitter(Fixture.Places.rome, seed: i + 100, meters: 80)) }
        coords.append(Fixture.Places.tegernsee)
        let result = GeoClusterer(epsilonMeters: 100, minPoints: 4).cluster(coords)
        #expect(result.clusters.count == 2)
        #expect(result.clusters[0].memberIndices.count == 30)
        #expect(result.clusters[1].memberIndices.count == 20)
        #expect(result.noise == [50])
    }

    @Test func continentLookup() {
        #expect(Continent.forCountryCode("it") == .europe)
        #expect(Continent.forCountryCode("JP") == .asia)
        #expect(Continent.forCountryCode("BR") == .southAmerica)
        #expect(Continent.forCountryCode("XX") == nil)
    }

    @Test func placeKeysIncludeParentsAndNormalize() throws {
        let rome = PlaceComponents(isoCountryCode: "IT", country: "Italien", administrativeArea: "Latium", locality: "Rom", subLocality: "Centro Storico")
        #expect(rome.key(at: .country)?.path == "it")
        #expect(rome.key(at: .locality)?.path == "it/latium/rom")
        #expect(rome.key(at: .subLocality)?.path == "it/latium/rom/centro-storico")
        #expect(rome.key(at: .subAdministrativeArea) == nil)
        let frankfurtMain = PlaceComponents(isoCountryCode: "DE", administrativeArea: "Hessen", locality: "Frankfurt am Main")
        let frankfurtOder = PlaceComponents(isoCountryCode: "DE", administrativeArea: "Brandenburg", locality: "Frankfurt (Oder)")
        #expect(frankfurtMain.key(at: .locality) != frankfurtOder.key(at: .locality))
        #expect(PlaceKey.normalize("Düsseldorf") == "dusseldorf")
        #expect(PlaceKey.normalize("Straße") == "strasse")
    }
}
