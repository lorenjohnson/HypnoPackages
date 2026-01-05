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
        let deletionsURL = tempDir.appendingPathComponent("deletions.json")
        let favoritesURL = tempDir.appendingPathComponent("favorites.json")

        let exclusionStore = ExclusionStore(url: exclusionURL)
        let deleteStore = DeleteStore(url: deletionsURL)
        let favoriteStore = FavoriteStore(url: favoritesURL)

        let fileURL = tempDir.appendingPathComponent("sample.mov")
        let fileSource = MediaFile.Source.url(fileURL)
        let photoSource = MediaFile.Source.photos(localIdentifier: "test-asset")

        favoriteStore.add(fileSource)
        exclusionStore.add(photoSource)
        deleteStore.add(fileSource)

        #expect(favoriteStore.isFavorited(fileSource))
        #expect(exclusionStore.isExcluded(photoSource))
        #expect(deleteStore.isQueued(fileSource))

        let exclusionStoreReload = ExclusionStore(url: exclusionURL)
        let deleteStoreReload = DeleteStore(url: deletionsURL)
        let favoriteStoreReload = FavoriteStore(url: favoritesURL)

        #expect(favoriteStoreReload.isFavorited(fileSource))
        #expect(exclusionStoreReload.isExcluded(photoSource))
        #expect(deleteStoreReload.isQueued(fileSource))
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
