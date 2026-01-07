//
//  ApplePhotosHooks.swift
//  HypnoCore
//
//  Configures HypnoCoreHooks with Apple Photos integration.
//  Call `ApplePhotosHooks.install()` at app startup to enable Photos support.
//

import Foundation
import AVFoundation
import CoreImage

/// Installs Apple Photos integration into HypnoCoreHooks.
/// This bridges the generic hook system to the ApplePhotos singleton.
public enum ApplePhotosHooks {

    /// Install Apple Photos integration into HypnoCoreHooks.
    /// Call this at app startup (e.g., in App.init()) to enable Photos support.
    public static func install() {
        HypnoCoreHooks.shared.resolveExternalVideo = { identifier in
            guard let phAsset = ApplePhotos.shared.fetchAsset(localIdentifier: identifier) else {
                return nil
            }
            return await ApplePhotos.shared.requestAVAsset(for: phAsset)
        }

        HypnoCoreHooks.shared.resolveExternalImage = { identifier in
            guard let phAsset = ApplePhotos.shared.fetchAsset(localIdentifier: identifier) else {
                return nil
            }
            return await ApplePhotos.shared.requestCIImage(for: phAsset)
        }

        HypnoCoreHooks.shared.onVideoExportCompleted = { url in
            if ApplePhotos.shared.status.canWrite {
                let success = await ApplePhotos.shared.saveVideo(at: url)
                if success {
                    print("✅ ApplePhotosHooks: Video saved to Photos")
                }
            }
        }

        HypnoCoreHooks.shared.onImageExportCompleted = { url in
            if ApplePhotos.shared.status.canWrite {
                let success = await ApplePhotos.shared.saveImage(at: url)
                if success {
                    print("✅ ApplePhotosHooks: Image saved to Photos")
                }
            }
        }
    }
}
