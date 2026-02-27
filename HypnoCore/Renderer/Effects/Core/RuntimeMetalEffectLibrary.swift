//
//  RuntimeMetalEffectLibrary.swift
//  Hypnograph
//
//  Loads user-editable Metal effect assets from Application Support.
//  Asset format:
//  - runtime-effects/<uuid>/effect.json
//  - runtime-effects/<uuid>/shader.metal
//

import Foundation

public enum RuntimeMetalTextureSource: String, Codable, Equatable {
    case currentFrame
    case historyFrame
}

public struct RuntimeMetalTextureBindingManifest: Codable, Equatable {
    public var argumentIndex: Int
    public var source: RuntimeMetalTextureSource
    public var historyOffset: Int?
    public var historyOffsetParameter: String?
    public var historyOffsetScale: Double?
    public var historyOffsetBias: Int?

    public init(
        argumentIndex: Int,
        source: RuntimeMetalTextureSource,
        historyOffset: Int? = nil,
        historyOffsetParameter: String? = nil,
        historyOffsetScale: Double? = nil,
        historyOffsetBias: Int? = nil
    ) {
        self.argumentIndex = argumentIndex
        self.source = source
        self.historyOffset = historyOffset
        self.historyOffsetParameter = historyOffsetParameter
        self.historyOffsetScale = historyOffsetScale
        self.historyOffsetBias = historyOffsetBias
    }
}

public struct RuntimeMetalBindingsManifest: Codable, Equatable {
    public var parameterBufferIndex: Int?
    public var inputTextures: [RuntimeMetalTextureBindingManifest]
    public var outputTextureIndex: Int

    public init(
        parameterBufferIndex: Int? = 0,
        inputTextures: [RuntimeMetalTextureBindingManifest],
        outputTextureIndex: Int
    ) {
        self.parameterBufferIndex = parameterBufferIndex
        self.inputTextures = inputTextures
        self.outputTextureIndex = outputTextureIndex
    }
}

public struct RuntimeMetalChoiceOption: Codable, Equatable {
    public var key: String
    public var label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

public struct RuntimeMetalParameterSchemaEntry: Codable, Equatable {
    public var type: String
    public var defaultValue: AnyCodableValue
    public var min: Double?
    public var max: Double?
    public var options: [RuntimeMetalChoiceOption]?

    enum CodingKeys: String, CodingKey {
        case type
        case defaultValue = "default"
        case min
        case max
        case options
    }

    public init(
        type: String,
        defaultValue: AnyCodableValue,
        min: Double? = nil,
        max: Double? = nil,
        options: [RuntimeMetalChoiceOption]? = nil
    ) {
        self.type = type
        self.defaultValue = defaultValue
        self.min = min
        self.max = max
        self.options = options
    }
}

public struct RuntimeMetalEffectManifest: Codable, Equatable {
    public var uuid: String
    public var name: String
    public var version: String
    public var legacyTypes: [String]?
    public var runtimeKind: EffectRuntimeKind?
    public var requiredLookback: Int?
    public var usesPersistentState: Bool?
    public var parameters: [String: RuntimeMetalParameterSchemaEntry]
    public var parameterOrder: [String]?
    public var autoBoundParameters: [String]?
    public var bindings: RuntimeMetalBindingsManifest

    public init(
        uuid: String,
        name: String,
        version: String,
        legacyTypes: [String]? = nil,
        runtimeKind: EffectRuntimeKind? = nil,
        requiredLookback: Int? = nil,
        usesPersistentState: Bool? = nil,
        parameters: [String: RuntimeMetalParameterSchemaEntry],
        parameterOrder: [String]? = nil,
        autoBoundParameters: [String]? = nil,
        bindings: RuntimeMetalBindingsManifest
    ) {
        self.uuid = uuid
        self.name = name
        self.version = version
        self.legacyTypes = legacyTypes
        self.runtimeKind = runtimeKind
        self.requiredLookback = requiredLookback
        self.usesPersistentState = usesPersistentState
        self.parameters = parameters
        self.parameterOrder = parameterOrder
        self.autoBoundParameters = autoBoundParameters
        self.bindings = bindings
    }
}

public struct RuntimeMetalEffectDefinition {
    public var typeName: String
    public var uuid: String
    public var name: String
    public var version: String
    public var sourceCode: String
    public var parameterSpecs: [String: ParameterSpec]
    public var parameterOrder: [String]
    public var allParameterDefaults: [String: AnyCodableValue]
    public var autoBoundParameters: Set<String>
    public var bindings: RuntimeMetalBindingsManifest
    public var requiredLookback: Int
    public var usesPersistentState: Bool
    public var runtimeKind: EffectRuntimeKind
}

public final class RuntimeMetalEffectLibrary {
    public static let shared = RuntimeMetalEffectLibrary()
    public static let typePrefix = "RuntimeMetal:"
    public static let defaultFunctionName = "render"
    public static let fallbackEffectUUID = "b3d67013-560d-498e-9cb8-c99714ed8b4a"

    public static func typeName(forUUID uuid: String) -> String {
        "\(typePrefix)\(uuid)"
    }

    public static func uuid(fromTypeName typeName: String) -> String? {
        guard isRuntimeType(typeName) else { return nil }
        return String(typeName.dropFirst(typePrefix.count))
    }

    public static func isRuntimeType(_ typeName: String) -> Bool {
        typeName.hasPrefix(typePrefix)
    }

    private var didLoad = false
    private var definitionsByType: [String: RuntimeMetalEffectDefinition] = [:]
    private let lock = NSLock()

    private init() {}

    public func reload() {
        lock.lock()
        didLoad = false
        definitionsByType = [:]
        lock.unlock()
        _ = allDefinitions()
    }

    public func definition(for typeName: String) -> RuntimeMetalEffectDefinition? {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        return definitionsByType[typeName]
    }

    public func allDefinitions() -> [RuntimeMetalEffectDefinition] {
        ensureLoaded()
        lock.lock()
        defer { lock.unlock() }
        var uniqueByUUID: [String: RuntimeMetalEffectDefinition] = [:]
        for definition in definitionsByType.values {
            if uniqueByUUID[definition.uuid] == nil {
                uniqueByUUID[definition.uuid] = definition
            }
        }
        return uniqueByUUID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func ensureLoaded() {
        lock.lock()
        let shouldLoad = !didLoad
        lock.unlock()
        guard shouldLoad else { return }

        let loaded = loadDefinitions()
        lock.lock()
        definitionsByType = loaded
        didLoad = true
        lock.unlock()
    }

    private func loadDefinitions() -> [String: RuntimeMetalEffectDefinition] {
        seedRuntimeAssetsIfNeeded()

        var loaded: [String: RuntimeMetalEffectDefinition] = [:]
        let directory = HypnoCoreConfig.shared.runtimeEffectsDirectory
        let fm = FileManager.default

        guard let urls = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return loaded
        }

        for effectDirectory in urls {
            guard (try? effectDirectory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let manifestURL = effectDirectory.appendingPathComponent("effect.json")
            let shaderURL = effectDirectory.appendingPathComponent("shader.metal")
            guard fm.fileExists(atPath: manifestURL.path), fm.fileExists(atPath: shaderURL.path) else {
                continue
            }

            do {
                let manifestData = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder().decode(RuntimeMetalEffectManifest.self, from: manifestData)
                let shaderSource = try String(contentsOf: shaderURL, encoding: .utf8)
                let definition = Self.buildDefinition(manifest: manifest, sourceCode: shaderSource)
                loaded[definition.typeName] = definition
                for legacy in manifest.legacyTypes ?? [] {
                    let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    loaded[trimmed] = definition
                    let aliasType = Self.normalizedRuntimeTypeAlias(trimmed)
                    loaded[aliasType] = definition
                }
            } catch {
                print("⚠️ RuntimeMetalEffectLibrary: Failed to load asset at \(effectDirectory.lastPathComponent): \(error)")
            }
        }

        return loaded
    }

    private func seedRuntimeAssetsIfNeeded() {
        let targetDirectory = HypnoCoreConfig.shared.runtimeEffectsDirectory
        let fm = FileManager.default

        if let bundled = bundledRuntimeAssetsDirectory() {
            do {
                let bundledItems = try fm.contentsOfDirectory(
                    at: bundled,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )

                for item in bundledItems {
                    guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                        continue
                    }

                    let destination = targetDirectory.appendingPathComponent(item.lastPathComponent, isDirectory: true)
                    if !fm.fileExists(atPath: destination.path) {
                        do {
                            try fm.copyItem(at: item, to: destination)
                        } catch let error as NSError {
                            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                                continue
                            }
                            print("⚠️ RuntimeMetalEffectLibrary: Failed to copy bundled runtime asset \(item.lastPathComponent): \(error)")
                        }
                    } else {
                        do {
                            let decision = try replacementDecisionForBundledAsset(item, existingAsset: destination)
                            if decision.shouldReplace {
                                try replaceRuntimeAsset(at: destination, withBundledAssetAt: item)
                                print("ℹ️ RuntimeMetalEffectLibrary: Updated runtime asset \(item.lastPathComponent) \(decision.reason)")
                            }
                        } catch {
                            print("⚠️ RuntimeMetalEffectLibrary: Failed to evaluate bundled update for \(item.lastPathComponent): \(error)")
                        }
                    }
                }
            } catch {
                print("⚠️ RuntimeMetalEffectLibrary: Failed to seed bundled assets: \(error)")
            }
        }

        // Safety fallback for debug/tests when bundle resource copying is unavailable.
        let fallbackDirectory = targetDirectory.appendingPathComponent(Self.fallbackEffectUUID, isDirectory: true)
        let fallbackManifest = fallbackDirectory.appendingPathComponent("effect.json")
        let fallbackShader = fallbackDirectory.appendingPathComponent("shader.metal")
        if !fm.fileExists(atPath: fallbackManifest.path) || !fm.fileExists(atPath: fallbackShader.path) {
            do {
                if !fm.fileExists(atPath: fallbackDirectory.path) {
                    try fm.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
                }
                try Self.fallbackManifestJSON.write(to: fallbackManifest, atomically: true, encoding: .utf8)
                try Self.fallbackShaderSource.write(to: fallbackShader, atomically: true, encoding: .utf8)
            } catch {
                print("⚠️ RuntimeMetalEffectLibrary: Failed to seed fallback runtime effect: \(error)")
            }
        }
    }

    private struct RuntimeAssetReplacementDecision {
        var shouldReplace: Bool
        var reason: String
    }

    private func replacementDecisionForBundledAsset(
        _ bundledAsset: URL,
        existingAsset: URL
    ) throws -> RuntimeAssetReplacementDecision {
        let bundledManifestURL = bundledAsset.appendingPathComponent("effect.json")
        let bundledShaderURL = bundledAsset.appendingPathComponent("shader.metal")
        guard FileManager.default.fileExists(atPath: bundledManifestURL.path),
              FileManager.default.fileExists(atPath: bundledShaderURL.path) else {
            return RuntimeAssetReplacementDecision(
                shouldReplace: false,
                reason: "(missing bundled effect.json or shader.metal)"
            )
        }

        let existingManifestURL = existingAsset.appendingPathComponent("effect.json")
        let existingShaderURL = existingAsset.appendingPathComponent("shader.metal")
        guard FileManager.default.fileExists(atPath: existingManifestURL.path),
              FileManager.default.fileExists(atPath: existingShaderURL.path) else {
            return RuntimeAssetReplacementDecision(
                shouldReplace: true,
                reason: "(existing asset incomplete; replaced with bundled copy)"
            )
        }

        let decoder = JSONDecoder()
        let bundledData = try Data(contentsOf: bundledManifestURL)
        let bundledManifest = try decoder.decode(RuntimeMetalEffectManifest.self, from: bundledData)

        let existingData = try Data(contentsOf: existingManifestURL)
        let existingManifest = try decoder.decode(RuntimeMetalEffectManifest.self, from: existingData)

        guard bundledManifest.uuid == existingManifest.uuid else {
            return RuntimeAssetReplacementDecision(
                shouldReplace: false,
                reason: "(UUID mismatch existing=\(existingManifest.uuid) bundled=\(bundledManifest.uuid); keeping existing)"
            )
        }

        let comparison = Self.compareSemanticVersions(
            bundledManifest.version,
            existingManifest.version
        )

        if comparison == .orderedDescending {
            return RuntimeAssetReplacementDecision(
                shouldReplace: true,
                reason: "(same UUID, bundled version \(bundledManifest.version) > existing \(existingManifest.version))"
            )
        }

        return RuntimeAssetReplacementDecision(
            shouldReplace: false,
            reason: "(same UUID, bundled version \(bundledManifest.version) <= existing \(existingManifest.version))"
        )
    }

    private func replaceRuntimeAsset(at destination: URL, withBundledAssetAt source: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        let backup = parent.appendingPathComponent(".runtime-effect-backup-\(destination.lastPathComponent)-\(UUID().uuidString)")

        try fm.moveItem(at: destination, to: backup)
        do {
            try fm.copyItem(at: source, to: destination)
            try? fm.removeItem(at: backup)
        } catch {
            try? fm.removeItem(at: destination)
            if fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private struct SemanticVersion: Comparable {
        private enum Identifier: Equatable {
            case numeric(Int)
            case text(String)
        }

        let major: Int
        let minor: Int
        let patch: Int
        private let prerelease: [Identifier]

        init?(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let withoutBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
            let splitPre = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = splitPre.first.map(String.init) ?? withoutBuild
            let coreParts = core.split(separator: ".", omittingEmptySubsequences: false)
            guard !coreParts.isEmpty, coreParts.count <= 3 else { return nil }

            guard let major = Int(coreParts[0]) else { return nil }
            let minor: Int
            if coreParts.count > 1 {
                guard let parsed = Int(coreParts[1]) else { return nil }
                minor = parsed
            } else {
                minor = 0
            }

            let patch: Int
            if coreParts.count > 2 {
                guard let parsed = Int(coreParts[2]) else { return nil }
                patch = parsed
            } else {
                patch = 0
            }

            let prereleaseIdentifiers: [Identifier]
            if splitPre.count > 1 {
                let prereleasePart = String(splitPre[1])
                let identifiers = prereleasePart.split(separator: ".", omittingEmptySubsequences: false)
                guard !identifiers.contains(where: { $0.isEmpty }) else { return nil }
                prereleaseIdentifiers = identifiers.map { token in
                    if let numeric = Int(token) {
                        return .numeric(numeric)
                    }
                    return .text(String(token))
                }
            } else {
                prereleaseIdentifiers = []
            }

            self.major = major
            self.minor = minor
            self.patch = patch
            self.prerelease = prereleaseIdentifiers
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

            if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
            if lhs.prerelease.isEmpty { return false }
            if rhs.prerelease.isEmpty { return true }

            let maxCount = max(lhs.prerelease.count, rhs.prerelease.count)
            for index in 0..<maxCount {
                guard index < lhs.prerelease.count else { return true }
                guard index < rhs.prerelease.count else { return false }

                let left = lhs.prerelease[index]
                let right = rhs.prerelease[index]
                if left == right { continue }

                switch (left, right) {
                case let (.numeric(a), .numeric(b)):
                    return a < b
                case (.numeric, .text):
                    return true
                case (.text, .numeric):
                    return false
                case let (.text(a), .text(b)):
                    return a.localizedStandardCompare(b) == .orderedAscending
                }
            }

            return false
        }
    }

    private static func compareSemanticVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = SemanticVersion(lhs), let right = SemanticVersion(rhs) {
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }

        return lhs.compare(rhs, options: [.numeric, .caseInsensitive])
    }

    private func bundledRuntimeAssetsDirectory() -> URL? {
        if let explicit = HypnoEffectsBundle.bundle.url(forResource: "RuntimeAssets", withExtension: nil) {
            return explicit
        }
        guard let resourceURL = HypnoEffectsBundle.bundle.resourceURL else { return nil }
        let candidate = resourceURL.appendingPathComponent("RuntimeAssets", isDirectory: true)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private static func buildDefinition(
        manifest: RuntimeMetalEffectManifest,
        sourceCode: String
    ) -> RuntimeMetalEffectDefinition {
        var editableSpecs: [String: ParameterSpec] = [:]
        var allDefaults: [String: AnyCodableValue] = [:]
        var warnings: [String] = []

        let autoBound = Set(manifest.autoBoundParameters ?? [])
        for (name, entry) in manifest.parameters {
            allDefaults[name] = entry.defaultValue
            if autoBound.contains(name) { continue }
            guard let spec = parameterSpec(from: entry) else {
                warnings.append("Unsupported parameter schema for '\(name)' in runtime effect '\(manifest.uuid)'.")
                continue
            }
            editableSpecs[name] = spec
        }

        if !warnings.isEmpty {
            print("⚠️ RuntimeMetalEffectLibrary: \(warnings.joined(separator: " "))")
        }

        let orderedEditableNames: [String]
        if let explicitOrder = manifest.parameterOrder, !explicitOrder.isEmpty {
            var merged = explicitOrder.filter { editableSpecs[$0] != nil }
            merged.append(contentsOf: editableSpecs.keys.sorted().filter { !merged.contains($0) })
            orderedEditableNames = merged
        } else {
            orderedEditableNames = editableSpecs.keys.sorted()
        }

        let historyLookback = manifest.bindings.inputTextures
            .compactMap { binding -> Int? in
                guard binding.source == .historyFrame else { return nil }
                return binding.historyOffset
            }
            .max() ?? 0

        let requiredLookback = max(manifest.requiredLookback ?? 0, historyLookback)
        let usesPersistentState = manifest.usesPersistentState ?? false
        let runtimeKind = manifest.runtimeKind ?? .metal

        return RuntimeMetalEffectDefinition(
            typeName: typeName(forUUID: manifest.uuid),
            uuid: manifest.uuid,
            name: manifest.name,
            version: manifest.version,
            sourceCode: sourceCode,
            parameterSpecs: editableSpecs,
            parameterOrder: orderedEditableNames,
            allParameterDefaults: allDefaults,
            autoBoundParameters: autoBound,
            bindings: manifest.bindings,
            requiredLookback: requiredLookback,
            usesPersistentState: usesPersistentState,
            runtimeKind: runtimeKind
        )
    }

    private static func parameterSpec(from entry: RuntimeMetalParameterSchemaEntry) -> ParameterSpec? {
        switch entry.type.lowercased() {
        case "float":
            let defaultValue = entry.defaultValue.floatValue ?? 0
            let minValue = Float(entry.min ?? 0)
            let maxValue = Float(entry.max ?? 1)
            return .float(default: defaultValue, range: minValue...maxValue)

        case "double":
            let defaultValue = entry.defaultValue.doubleValue ?? 0
            let minValue = entry.min ?? 0
            let maxValue = entry.max ?? 1
            return .double(default: defaultValue, range: minValue...maxValue)

        case "int":
            let defaultValue = entry.defaultValue.intValue ?? 0
            let minValue = Int(entry.min ?? 0)
            let maxValue = Int(entry.max ?? 1)
            return .int(default: defaultValue, range: minValue...maxValue)

        case "uint":
            let defaultValue = max(0, entry.defaultValue.intValue ?? 0)
            let minValue = max(0, Int(entry.min ?? 0))
            let maxValue = max(minValue + 1, Int(entry.max ?? Double(max(minValue + 1, defaultValue + 1))))
            return .int(default: defaultValue, range: minValue...maxValue)

        case "bool":
            return .bool(default: entry.defaultValue.boolValue ?? false)

        case "choice":
            let options = (entry.options ?? []).map { (key: $0.key, label: $0.label) }
            let defaultValue = entry.defaultValue.stringValue ?? options.first?.key ?? ""
            return .choice(default: defaultValue, options: options)

        case "color":
            return .color(default: entry.defaultValue.stringValue ?? "#FFFFFF")

        default:
            return nil
        }
    }

    private static func normalizedRuntimeTypeAlias(_ legacyType: String) -> String {
        let trimmed = legacyType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return typePrefix + fallbackEffectUUID }
        if isRuntimeType(trimmed) {
            return trimmed
        }
        return "\(typePrefix)\(trimmed)"
    }

    private static let fallbackManifestJSON = """
    {
      "uuid": "\(fallbackEffectUUID)",
      "name": "RGB Split",
      "version": "1.0.0",
      "legacyTypes": ["rgb_split"],
      "runtimeKind": "metal",
      "requiredLookback": 0,
      "usesPersistentState": false,
      "parameters": {
        "offsetAmount": { "type": "float", "default": 10.0, "min": 0.0, "max": 500.0 },
        "animated": { "type": "bool", "default": true },
        "timeSeconds": { "type": "float", "default": 0.0, "min": 0.0, "max": 100000.0 },
        "textureWidth": { "type": "int", "default": 1920, "min": 1.0, "max": 8192.0 },
        "textureHeight": { "type": "int", "default": 1080, "min": 1.0, "max": 8192.0 }
      },
      "parameterOrder": ["offsetAmount", "animated", "timeSeconds", "textureWidth", "textureHeight"],
      "autoBoundParameters": ["timeSeconds", "textureWidth", "textureHeight"],
      "bindings": {
        "parameterBufferIndex": 0,
        "inputTextures": [
          { "argumentIndex": 0, "source": "currentFrame" }
        ],
        "outputTextureIndex": 1
      }
    }
    """

    private static let fallbackShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct HypnoParams {
        float offsetAmount;
        int animated;
        float timeSeconds;
        int textureWidth;
        int textureHeight;
    };

    inline float animatedPhase(float t) {
        float slow = sin(t * 0.7);
        float medium = sin(t * 2.3 + 1.5) * 0.4;
        float fast = sin(t * 7.1 + 3.0) * 0.15;
        float erratic = sin(t * 13.7 + t * 0.3) * 0.1;
        float combined = slow + medium + fast + erratic;
        return (combined + 1.0) * 0.45 + 0.1;
    }

    kernel void render(
        texture2d<float, access::sample> inputTexture [[texture(0)]],
        texture2d<float, access::write> outputTexture [[texture(1)]],
        constant HypnoParams& params [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= uint(params.textureWidth) || gid.y >= uint(params.textureHeight)) {
            return;
        }

        constexpr sampler samplerLinear(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

        float2 texSize = float2(params.textureWidth, params.textureHeight);
        float2 uv = (float2(gid) + 0.5) / texSize;

        float offsetPixels = params.offsetAmount;
        if (params.animated != 0) {
            offsetPixels *= animatedPhase(params.timeSeconds);
        }
        float offsetUV = offsetPixels / max(texSize.x, 1.0);

        float4 center = inputTexture.sample(samplerLinear, uv);
        float4 redShifted = inputTexture.sample(samplerLinear, uv + float2(offsetUV, 0.0));
        float4 blueShifted = inputTexture.sample(samplerLinear, uv - float2(offsetUV, 0.0));

        float3 rgb = float3(redShifted.r, center.g, blueShifted.b);
        outputTexture.write(float4(clamp(rgb, 0.0, 1.0), center.a), gid);
    }
    """
}
