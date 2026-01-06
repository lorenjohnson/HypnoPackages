////
////  RenderQueue.swift
////  Hypnograph
////
////  Created by Loren Johnson on 15.11.25.
////

import Foundation

/// Manages a queue of rendering jobs for Hypnogram.
/// Keeps track of active jobs, but is agnostic about which renderer is used.
final class RenderQueue {

    /// Number of currently active jobs (being processed).
    /// Not @Published to avoid triggering view updates during rendering
    private(set) var activeJobs: Int = 0

    /// Called on the main thread whenever `activeJobs` drops to 0.
    /// The app can use this to e.g. reply to `applicationShouldTerminate`.
    var onAllJobsFinished: (() -> Void)?

    /// Optional status messages for UI surfaces to display.
    var onStatusMessage: ((String) -> Void)?

    init() { }

    /// Enqueue a new HypnogramRecipe for rendering with the given renderer.
    func enqueue(
        renderer: HypnogramRenderer,
        recipe: HypnogramRecipe,
        completion: ((Result<URL, Error>) -> Void)? = nil
    ) {
        activeJobs += 1
        onStatusMessage?("Rendering started")

        renderer.enqueue(recipe: recipe) { [weak self] result in
            guard let self = self else { return }

            // Completion is already called on MainActor by HypnogramRenderer
            // Update state directly since we're already on MainActor
            self.activeJobs -= 1

            switch result {
            case .success(let url):
                print("Render job finished: \(url.path)")
                onStatusMessage?("Saved: \(url.lastPathComponent)")

                // Also save to Apple Photos if write access is available
                if ApplePhotos.shared.status.canWrite {
                    Task {
                        let success = await ApplePhotos.shared.saveVideo(at: url)
                        if success {
                            print("✅ RenderQueue: Render added to Apple Photos")
                        }
                    }
                }

            case .failure(let error):
                print("Render job failed: \(error.localizedDescription)")
                onStatusMessage?("Save failed: \(error.localizedDescription)")
            }

            // Call per-job completion if provided
            completion?(result)

            if self.activeJobs == 0 {
                self.onAllJobsFinished?()
            }
        }
    }
}
