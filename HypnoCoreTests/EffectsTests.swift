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
        let layer = HypnogramLayer(mediaClip: mediaClip, effectChain: chain)
        let hypnogram = Hypnogram(layers: [layer], targetDuration: duration)

        let manager = EffectManager()
        manager.clipProvider = { hypnogram }

        #expect(manager.maxRequiredLookback == 2)
        #expect(manager.usesFrameBuffer)
    }

    @Test func hypnographSessionCodableRoundTrip() throws {
        let duration = CMTime(seconds: 3, preferredTimescale: 600)
        let file = MediaFile(source: .url(URL(fileURLWithPath: "/tmp/recipe.mov")), mediaKind: .video, duration: duration)
        let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
        let transform = CGAffineTransform(a: 1, b: 0.1, c: -0.1, d: 1, tx: 5, ty: -3)
        let chain = EffectChain(name: "Global", effects: [EffectDefinition(type: "BasicEffect")])
        let layer = HypnogramLayer(mediaClip: mediaClip, transforms: [transform], blendMode: BlendMode.sourceOver, effectChain: chain)
        let session = HypnographSession(layers: [layer], targetDuration: duration, playRate: 0.8, effectChain: chain)

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(HypnographSession.self, from: data)

        #expect(decoded.hypnograms.count == 1)
        #expect(decoded.hypnograms[0].layers.count == 1)
        #expect(decoded.hypnograms[0].targetDuration.seconds == session.hypnograms[0].targetDuration.seconds)
        #expect(decoded.hypnograms[0].playRate == session.hypnograms[0].playRate)

        let decodedTransform = decoded.hypnograms[0].layers[0].transforms[0]
        #expect(decodedTransform.a == transform.a)
        #expect(decodedTransform.b == transform.b)
        #expect(decodedTransform.c == transform.c)
        #expect(decodedTransform.d == transform.d)
        #expect(decodedTransform.tx == transform.tx)
        #expect(decodedTransform.ty == transform.ty)
    }

    @Test func hypnographSessionEnsureEffectChainNames() {
        let duration = CMTime(seconds: 1, preferredTimescale: 600)
        let file = MediaFile(source: .url(URL(fileURLWithPath: "/tmp/ensure.mov")), mediaKind: .video, duration: duration)
        let mediaClip = MediaClip(file: file, startTime: .zero, duration: duration)
        let sourceChain = EffectChain(name: nil, effects: [EffectDefinition(type: "BasicEffect")])
        let layer = HypnogramLayer(mediaClip: mediaClip, effectChain: sourceChain)

        var session = HypnographSession(
            layers: [layer],
            targetDuration: duration,
            effectChain: EffectChain(name: nil, effects: [EffectDefinition(type: "BasicEffect")])
        )

        session.ensureEffectChainNames()

        #expect(session.hypnograms[0].effectChain.name != nil)
        #expect(session.hypnograms[0].layers[0].effectChain.name != nil)
    }
}
