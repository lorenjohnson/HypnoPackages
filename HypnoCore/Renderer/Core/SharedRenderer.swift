//
//  SharedRenderer.swift
//  Hypnograph
//
//  Shared Metal device and CIContext for efficient GPU resource reuse.
//  Extracted from RenderHooks.swift as part of effects architecture refactor.
//

import CoreImage
import Metal

/// Shared Metal device and CIContext for efficient GPU resource reuse
public enum SharedRenderer {
    public static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Shared CIContext for all rendering - Metal-backed, no intermediate caching
    public static let ciContext: CIContext = {
        if let device = metalDevice {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .priorityRequestLow: false
            ])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
}
