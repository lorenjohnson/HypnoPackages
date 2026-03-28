//
//  EffectsTests.swift
//  EffectsTests
//
//  Created by Loren Johnson on 15.11.25.
//

import Testing
import CoreMedia
import CoreGraphics
import HypnoCore

struct EffectsTests {

    @Test func effectManagerDetectsTemporalLookback() {
        let duration = CMTime(seconds: 1, preferredTimescale: 600)
        let file = MediaFile(
            source: .url(URL(fileURLWithPath: "/tmp/placeholder.png")),
            mediaKind: .image,
            duration: duration
        )
        let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
        let chain = EffectChain(name: "Temporal", effects: [EffectDefinition(type: "FrameDifferenceEffect")])
        let layer = Layer(mediaClip: mediaClip, effectChain: chain)
        let composition = Composition(layers: [layer], targetDuration: duration)

        let manager = EffectManager()
        manager.compositionProvider = { composition }

        #expect(manager.maxRequiredLookback == 2)
        #expect(manager.usesFrameBuffer)
    }

    @Test func hypnogramCodableRoundTripUsesLegacyTopLevelKey() throws {
        let duration = CMTime(seconds: 3, preferredTimescale: 600)
        let file = MediaFile(source: .url(URL(fileURLWithPath: "/tmp/recipe.mov")), mediaKind: .video, duration: duration)
        let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
        let transform = CGAffineTransform(a: 1, b: 0.1, c: -0.1, d: 1, tx: 5, ty: -3)
        let chain = EffectChain(name: "Global", effects: [EffectDefinition(type: "BasicEffect")])
        let layer = Layer(mediaClip: mediaClip, transforms: [transform], blendMode: BlendMode.sourceOver, effectChain: chain)
        let hypnogram = Hypnogram(layers: [layer], targetDuration: duration, playRate: 0.8, effectChain: chain)

        let data = try JSONEncoder().encode(hypnogram)
        let decoded = try JSONDecoder().decode(Hypnogram.self, from: data)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(root["hypnograms"] != nil)
        #expect(root["compositions"] == nil)
        #expect(decoded.compositions.count == 1)
        #expect(decoded.compositions[0].layers.count == 1)
        #expect(decoded.compositions[0].targetDuration.seconds == hypnogram.compositions[0].targetDuration.seconds)
        #expect(decoded.compositions[0].playRate == hypnogram.compositions[0].playRate)

        let decodedTransform = decoded.compositions[0].layers[0].transforms[0]
        #expect(decodedTransform.a == transform.a)
        #expect(decodedTransform.b == transform.b)
        #expect(decodedTransform.c == transform.c)
        #expect(decodedTransform.d == transform.d)
        #expect(decodedTransform.tx == transform.tx)
        #expect(decodedTransform.ty == transform.ty)
    }

    @Test func hypnogramDecodesLegacyClipsPayload() throws {
        let duration = CMTime(seconds: 2, preferredTimescale: 600)
        let layer = Layer(
            mediaClip: MediaClip(
                file: MediaFile(
                    source: .url(URL(fileURLWithPath: "/tmp/legacy-clips.mov")),
                    mediaKind: .video,
                    duration: duration
                ),
                startTime: .zero,
                duration: duration
            )
        )
        let composition = Composition(layers: [layer], targetDuration: duration, playRate: 0.75)
        let compositionJSON = try JSONEncoder().encode(composition)
        let compositionObject = try #require(JSONSerialization.jsonObject(with: compositionJSON) as? [String: Any])
        let payload: [String: Any] = [
            "clips": [compositionObject],
            "snapshot": "legacy-clips"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(Hypnogram.self, from: data)

        #expect(decoded.snapshot == "legacy-clips")
        #expect(decoded.compositions.count == 1)
        #expect(decoded.compositions[0].playRate == 0.75)
    }

    @Test func compositionDecodesLegacySourcesAndLayerClipPayload() throws {
        let duration = CMTime(seconds: 4, preferredTimescale: 600)
        let layer = Layer(
            mediaClip: MediaClip(
                file: MediaFile(
                    source: .url(URL(fileURLWithPath: "/tmp/legacy-layer.mov")),
                    mediaKind: .video,
                    duration: duration
                ),
                startTime: .zero,
                duration: duration
            )
        )
        let layerJSON = try JSONEncoder().encode(layer)
        let layerObject = try #require(JSONSerialization.jsonObject(with: layerJSON) as? [String: Any])
        var legacyLayerObject = layerObject
        legacyLayerObject["clip"] = legacyLayerObject.removeValue(forKey: "mediaClip")

        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "sources": [legacyLayerObject],
            "targetDuration": ["seconds": duration.seconds],
            "playRate": 0.5
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(Composition.self, from: data)

        #expect(decoded.layers.count == 1)
        #expect(decoded.layers[0].mediaClip.file.source.identifier == layer.mediaClip.file.source.identifier)
        #expect(decoded.playRate == 0.5)
        #expect(decoded.targetDuration.seconds == duration.seconds)
    }

    @Test func hypnogramEnsureEffectChainNames() {
        let duration = CMTime(seconds: 1, preferredTimescale: 600)
        let file = MediaFile(source: .url(URL(fileURLWithPath: "/tmp/ensure.mov")), mediaKind: .video, duration: duration)
        let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
        let sourceChain = EffectChain(name: nil, effects: [EffectDefinition(type: "BasicEffect")])
        let layer = Layer(mediaClip: mediaClip, effectChain: sourceChain)

        var hypnogram = Hypnogram(
            layers: [layer],
            targetDuration: duration,
            effectChain: EffectChain(name: nil, effects: [EffectDefinition(type: "BasicEffect")])
        )

        hypnogram.ensureEffectChainNames()

        #expect(hypnogram.compositions[0].effectChain.name != nil)
        #expect(hypnogram.compositions[0].layers[0].effectChain.name != nil)
    }

    @Test func instantiateChainWrapsAsSinglePassChainRuntimeUnit() {
        let chain = EffectChain(
            name: "Mixed Chain",
            effects: [
                EffectDefinition(type: "BasicEffect"),
                EffectDefinition(type: "LUTEffect")
            ]
        )

        let instantiated = EffectConfigLoader.instantiateChain(chain)
        #expect(instantiated.count == 1)
        #expect(instantiated[0] is PassChainEffect)

        let passChain = instantiated[0] as? PassChainEffect
        #expect(passChain?.runtimeDescriptors().count == 2)
    }

    @Test func effectChainRuntimeDescriptorClassifiesKinds() {
        let chain = EffectChain(
            name: "Runtime Descriptor",
            effects: [
                EffectDefinition(type: "BasicEffect"),
                EffectDefinition(type: "FrameDifferenceEffect"),
                EffectDefinition(type: "TextOverlayEffect")
            ]
        )

        let descriptor = chain.runtimeDescriptor
        #expect(descriptor.stages.count == 3)
        #expect(descriptor.maxRequiredLookback > 0)
        #expect(descriptor.usesPersistentState)
        #expect(descriptor.containsLegacyOrHybridStage)
    }

    @Test func runtimeMetalAssetEffectLoadsFromApplicationSupport() {
        let type = RuntimeMetalEffectLibrary.typeName(forUUID: RuntimeMetalEffectLibrary.fallbackEffectUUID)
        let legacyType = "RuntimeMetal:rgb_split"
        let legacyStaticType = "BasicEffect"

        let available = EffectRegistry.availableEffectTypes.map(\.type)
        #expect(available.contains(type))

        let specs = EffectRegistry.parameterSpecs(for: type)
        #expect(specs["offsetAmount"] != nil)
        #expect(specs["animated"] != nil)

        let runtimeEffect = EffectRegistry.create(type: type, params: nil)
        #expect(runtimeEffect != nil)

        let descriptor = EffectRegistry.runtimeDescriptor(for: type)
        #expect(descriptor?.runtimeKind == .metal)

        // Transitional alias support during UUID cutover.
        #expect(EffectRegistry.create(type: legacyType, params: nil) != nil)
        #expect(EffectRegistry.create(type: legacyStaticType, params: nil) != nil)
    }
}
