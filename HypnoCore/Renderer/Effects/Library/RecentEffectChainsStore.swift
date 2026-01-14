//
//  RecentEffectChainsStore.swift
//  HypnoCore
//
//  Global persistent store for recently replaced/cleared effect chains.
//  Dedupes by EffectChain.paramsHash.
//

import Foundation

@MainActor
public final class RecentEffectChainsStore: PersistentStore<RecentEffectChainsConfig> {

    public static let currentVersion: Int = 1

    public static let maxEntries: Int = 100

    public init(fileURL: URL) {
        let defaultConfig = RecentEffectChainsConfig(version: Self.currentVersion, entries: [])
        super.init(fileURL: fileURL, default: defaultConfig)
    }

    public convenience init() {
        self.init(fileURL: HypnoCoreConfig.shared.recentEffectChainsURL)
    }

    public var entries: [RecentEntry] {
        value.entries
    }

    public func addToFront(_ chain: EffectChain) {
        guard !chain.effects.isEmpty else { return }

        let paramsHash = chain.paramsHash
        let now = Date()
        let variantHint = String(paramsHash.prefix(6))

        update { config in
            var entries = config.entries

            if let existingIndex = entries.firstIndex(where: { $0.chain.paramsHash == paramsHash }) {
                var existing = entries.remove(at: existingIndex)
                existing.timestamp = now
                existing.chain = chain.clone()
                existing.sourceTemplateId = chain.sourceTemplateId
                existing.templateNameHint = chain.name
                existing.variantHint = variantHint
                entries.insert(existing, at: 0)
            } else {
                let entry = RecentEntry(
                    id: UUID(),
                    chain: chain.clone(),
                    timestamp: now,
                    sourceTemplateId: chain.sourceTemplateId,
                    templateNameHint: chain.name,
                    variantHint: variantHint
                )
                entries.insert(entry, at: 0)
            }

            if entries.count > Self.maxEntries {
                entries.removeLast(entries.count - Self.maxEntries)
            }

            config.entries = entries
            config.version = Self.currentVersion
        }
    }

    public func remove(id: UUID) {
        update { config in
            config.entries.removeAll { $0.id == id }
            config.version = Self.currentVersion
        }
    }
}

public struct RecentEffectChainsConfig: Codable {
    public var version: Int
    public var entries: [RecentEntry]

    public init(version: Int, entries: [RecentEntry]) {
        self.version = version
        self.entries = entries
    }
}

public struct RecentEntry: Codable, Identifiable {
    public var id: UUID
    public var chain: EffectChain
    public var timestamp: Date

    public var sourceTemplateId: UUID?
    public var templateNameHint: String?
    public var variantHint: String?

    public init(
        id: UUID,
        chain: EffectChain,
        timestamp: Date,
        sourceTemplateId: UUID?,
        templateNameHint: String?,
        variantHint: String?
    ) {
        self.id = id
        self.chain = chain
        self.timestamp = timestamp
        self.sourceTemplateId = sourceTemplateId
        self.templateNameHint = templateNameHint
        self.variantHint = variantHint
    }
}

