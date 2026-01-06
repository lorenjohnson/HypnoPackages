//
//  HypnogramRenderer.swift
//  Hypnograph
//
//  Renderer using RenderEngine for both montage and sequence export
//

import Foundation
import AVFoundation
import CoreMedia

/// Renderer that takes a HypnogramRecipe and produces a rendered movie file
final class HypnogramRenderer {

    private let outputFolder: URL
    private let outputSize: CGSize
    private let strategy: CompositionBuilder.TimelineStrategy

    init(outputURL: URL, outputSize: CGSize, strategy: CompositionBuilder.TimelineStrategy) {
        self.outputFolder = outputURL
        self.outputSize = outputSize
        self.strategy = strategy
    }

    // MARK: - Enqueue

    func enqueue(
        recipe: HypnogramRecipe,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        Task {
            let result = await render(recipe: recipe)
            
            await MainActor.run {
                switch result {
                case .success(let url):
                    completion(.success(url))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
    
    // MARK: - Render
    
    private func render(recipe: HypnogramRecipe) async -> Result<URL, Error> {
        print("🎬 HypnogramRenderer: Starting render...")
        
        // Prepare output URL
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "hypnograph-\(timestamp).mov"
        let outputURL = outputFolder.appendingPathComponent(filename)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create config for export
        let config = RenderEngine.Config(
            outputSize: outputSize,
            frameRate: 30,
            enableGlobalEffects: true  // enable effects for export (baked into output)
        )
        
        // Export using RenderEngine
        let engine = RenderEngine()
        let result = await engine.export(
            recipe: recipe,
            timeline: mapTimeline(strategy),
            outputURL: outputURL,
            config: config
        )
        
        switch result {
        case .success(let url):
            print("✅ HypnogramRenderer: Export complete - \(url.lastPathComponent)")
            return .success(url)
        case .failure(let error):
            print("🔴 HypnogramRenderer: Export failed - \(error)")
            return .failure(error)
        }
    }

    private func mapTimeline(_ strategy: CompositionBuilder.TimelineStrategy) -> RenderEngine.Timeline {
        switch strategy {
        case .montage(let targetDuration):
            return .montage(targetDuration: targetDuration)
        case .sequence:
            return .sequence
        }
    }
}
