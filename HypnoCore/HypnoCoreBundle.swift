import Foundation

enum HypnoCoreBundle {
    static let bundle: Bundle = {
#if SWIFT_PACKAGE
        Bundle.module
#else
        Bundle(for: BundleAnchor.self)
#endif
    }()

    private final class BundleAnchor {}
}
