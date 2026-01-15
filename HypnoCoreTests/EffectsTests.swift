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
        let clip = VideoClip(file: file, startTime: .zero, duration: duration)
        let chain = EffectChain(name: "Temporal", effects: [EffectDefinition(type: "FrameDifferenceEffect")])
        let source = HypnogramSource(clip: clip, effectChain: chain)
        let recipe = HypnogramRecipe(sources: [source], targetDuration: duration)

        let manager = EffectManager()
        manager.recipeProvider = { recipe }

        #expect(manager.maxRequiredLookback == 2)
        #expect(manager.usesFrameBuffer)
    }

    @Test func hypnogramRecipeCodableRoundTrip() throws {
        let duration = CMTime(seconds: 3, preferredTimescale: 600)
        let file = MediaFile(source: .url(URL(fileURLWithPath: "/tmp/recipe.mov")), mediaKind: .video, duration: duration)
        let clip = VideoClip(file: file, startTime: .zero, duration: duration)
        let transform = CGAffineTransform(a: 1, b: 0.1, c: -0.1, d: 1, tx: 5, ty: -3)
        let chain = EffectChain(name: "Global", effects: [EffectDefinition(type: "BasicEffect")])
        let source = HypnogramSource(clip: clip, transforms: [transform], blendMode: BlendMode.sourceOver, effectChain: chain)
        let recipe = HypnogramRecipe(sources: [source], targetDuration: duration, playRate: 0.8, effectChain: chain)

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(HypnogramRecipe.self, from: data)

        #expect(decoded.sources.count == 1)
        #expect(decoded.targetDuration.seconds == recipe.targetDuration.seconds)
        #expect(decoded.playRate == recipe.playRate)
        // Note: legacy recipe `mode` has been removed; decoding should remain stable.

        let decodedTransform = decoded.sources[0].transforms[0]
        #expect(decodedTransform.a == transform.a)
        #expect(decodedTransform.b == transform.b)
        #expect(decodedTransform.c == transform.c)
        #expect(decodedTransform.d == transform.d)
        #expect(decodedTransform.tx == transform.tx)
        #expect(decodedTransform.ty == transform.ty)
    }

    @Test func hypnogramRecipeEnsureEffectChainNames() {
        let duration = CMTime(seconds: 1, preferredTimescale: 600)
        let file = MediaFile(source: .url(URL(fileURLWithPath: "/tmp/ensure.mov")), mediaKind: .video, duration: duration)
        let clip = VideoClip(file: file, startTime: .zero, duration: duration)
        let sourceChain = EffectChain(name: nil, effects: [EffectDefinition(type: "BasicEffect")])
        let source = HypnogramSource(clip: clip, effectChain: sourceChain)

        var recipe = HypnogramRecipe(
            sources: [source],
            targetDuration: duration,
            effectChain: EffectChain(name: nil, effects: [EffectDefinition(type: "BasicEffect")])
        )

        recipe.ensureEffectChainNames()

        #expect(recipe.effectChain.name != nil)
        #expect(recipe.sources[0].effectChain.name != nil)
    }
}
