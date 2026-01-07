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

        let exclusionStore = ExclusionStore(url: exclusionURL)
        let deleteStore = DeleteStore(url: deletionsURL)

        let fileURL = tempDir.appendingPathComponent("sample.mov")
        let fileSource = MediaSource.url(fileURL)
        let externalSource = MediaSource.external(identifier: "test-asset")

        exclusionStore.add(externalSource)
        deleteStore.add(fileSource)

        #expect(exclusionStore.isExcluded(externalSource))
        #expect(deleteStore.isQueued(fileSource))

        let exclusionStoreReload = ExclusionStore(url: exclusionURL)
        let deleteStoreReload = DeleteStore(url: deletionsURL)

        #expect(exclusionStoreReload.isExcluded(externalSource))
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
