//
//  CoreStoreTests.swift
//  HypnoCoreTests
//
import Foundation
import Testing
import HypnoCore

struct CoreStoreTests {

    @Test func storesPersistInCustomDirectory() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let exclusionURL = tempDir.appendingPathComponent("exclusions.json")
        let favoritesURL = tempDir.appendingPathComponent("source-favorites.json")

        let exclusionStore = ExclusionStore(url: exclusionURL)
        let favoritesStore = SourceFavoritesStore(url: favoritesURL)

        let fileURL = tempDir.appendingPathComponent("sample.mov")
        let fileSource = MediaSource.url(fileURL)
        let externalSource = MediaSource.external(identifier: "test-asset")

        exclusionStore.add(externalSource)
        favoritesStore.add(fileSource)

        #expect(exclusionStore.isExcluded(externalSource))
        #expect(favoritesStore.isFavorite(fileSource))

        let exclusionStoreReload = ExclusionStore(url: exclusionURL)
        let favoritesStoreReload = SourceFavoritesStore(url: favoritesURL)

        #expect(exclusionStoreReload.isExcluded(externalSource))
        #expect(favoritesStoreReload.isFavorite(fileSource))
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hypnograph-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
