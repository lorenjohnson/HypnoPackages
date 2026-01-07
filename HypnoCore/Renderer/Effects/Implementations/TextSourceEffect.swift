//
//  TextOverlayEffect.swift
//  Hypnograph
//
//  Overlays random text from files in Application Support/<app>/text/
//
//  Architecture note: This effect is designed to transition to a TextSource type in the future.
//  The text selection, positioning, and timing logic are kept separable for easy extraction.
//  When that happens, this will support both random-from-disk mode and direct text input mode,
//  with the actual text sequence captured when materializing to a stored recipe.
//

import CoreImage
import CoreGraphics
import Foundation
import AppKit

// MARK: - Seeded Random Number Generator

/// A seedable random number generator for reproducible randomness.
/// Uses the same algorithm as the system RNG but with a fixed seed.
struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // xorshift64* algorithm - fast and good quality for our purposes
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545F4914F6CDD1D
    }
}

/// Text snippet with display properties
struct TextSnippet {
    let text: String
    var position: CGPoint
    var fontSize: CGFloat
    var opacity: Float
    var wrapExtension: CGFloat  // Fixed wrap width extension (set once at creation)
    var framesRemaining: Int
    var initialDuration: Int  // For fade in/out calculation
}

/// Overlays text loaded from text files onto frames
final class TextOverlayEffect: Effect {

    // MARK: - Parameter Specs

    static var parameterSpecs: [String: ParameterSpec] {
        [
            "fontSize": .float(default: 32.0, range: 8.0...120.0),
            "fontSizeVariation": .float(default: 0.3, range: 0.0...1.0),  // ±30% by default
            "opacity": .float(default: 0.8, range: 0.0...1.0),
            "maxTextCount": .int(default: 1, range: 1...10),
            "changeIntervalFrames": .int(default: 90, range: 10...600),
            "durationMultiplier": .float(default: 1.0, range: 0.5...10.0),  // frames = chars * multiplier * 4
            "textColor": .color(default: "#FFFFFF"),  // Text color (hex)
            "strokeWidth": .float(default: 2.0, range: 0.0...8.0),  // Outline width (0 = no stroke)
            "antialiasing": .bool(default: true)
        ]
    }

    // MARK: - Properties

    var name: String { "Text Overlay" }
    var requiredLookback: Int { 0 }

    var fontSize: Float
    var fontSizeVariation: Float
    var opacity: Float
    var maxTextCount: Int
    var changeIntervalFrames: Int
    var durationMultiplier: Float  // frames = text.count * multiplier
    var fontName: String
    var textColor: String  // Hex color string (e.g., "#FFFFFF")
    var strokeWidth: Float  // Outline width (0 = no stroke)
    var antialiasing: Bool

    /// Seed for reproducible randomness. Same seed = same text sequence, positions, timing.
    /// This enables live display to match preview exactly.
    let randomSeed: UInt64

    // State
    private var textLines: [String] = []
    private var activeSnippets: [TextSnippet] = []
    private var framesSinceLastAdd: Int = 0
    private var lastSize: CGSize = .zero
    private var isLoading = false
    private var hasLoaded = false

    /// Seeded random number generator for reproducible behavior
    private var rng: SeededRandomNumberGenerator

    // Position history to prevent clustering (tracks last N spawn positions)
    private var recentPositions: [CGPoint] = []
    private static let maxPositionHistory = 12  // Remember last 12 positions

    /// Shared text file loader instance
    private static let textFileLoader = TextFileLoader()

    // MARK: - Init

    init(fontSize: Float, fontSizeVariation: Float, opacity: Float, maxTextCount: Int,
         changeIntervalFrames: Int, durationMultiplier: Float, fontName: String, textColor: String,
         strokeWidth: Float, antialiasing: Bool, randomSeed: UInt64? = nil) {
        self.fontSize = fontSize
        self.fontSizeVariation = fontSizeVariation
        self.opacity = opacity
        self.maxTextCount = maxTextCount
        self.changeIntervalFrames = changeIntervalFrames
        self.durationMultiplier = durationMultiplier
        self.fontName = fontName
        self.textColor = textColor
        self.strokeWidth = strokeWidth
        self.antialiasing = antialiasing

        // Generate a new seed if not provided (first creation)
        // Copy operations pass the existing seed for reproducibility
        let seed = randomSeed ?? UInt64.random(in: 0...UInt64.max)
        self.randomSeed = seed
        self.rng = SeededRandomNumberGenerator(seed: seed)

        // Don't load here - lazy load on first use
    }

    required convenience init?(params: [String: AnyCodableValue]?) {
        let p = Params(params, specs: Self.parameterSpecs)
        let randomSeed = params?["randomSeed"]?.intValue.flatMap { UInt64($0) }
        self.init(fontSize: p.float("fontSize"), fontSizeVariation: p.float("fontSizeVariation"),
                  opacity: p.float("opacity"), maxTextCount: p.int("maxTextCount"),
                  changeIntervalFrames: p.int("changeIntervalFrames"), durationMultiplier: p.float("durationMultiplier"),
                  fontName: params?["fontName"]?.stringValue ?? "Menlo", textColor: p.string("textColor"),
                  strokeWidth: p.float("strokeWidth"), antialiasing: p.bool("antialiasing"), randomSeed: randomSeed)
    }

    // MARK: - Text Loading (Lazy, Async)

    /// Trigger async loading if not already loaded
    private func ensureTextLoaded() {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true

        // Load on background queue to avoid blocking main thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadTextFilesSync()
            DispatchQueue.main.async {
                self?.isLoading = false
                self?.hasLoaded = true
            }
        }
    }

    private func loadTextFilesSync() {
        let textDir = HypnoCoreConfig.shared.textDirectory
        let loadedLines = Self.textFileLoader.loadTextLines(from: textDir)

        // Thread-safe update
        DispatchQueue.main.async { [weak self] in
            self?.textLines = loadedLines
        }
    }

    private func randomLine() -> String {
        guard !textLines.isEmpty else { return "No text" }
        let index = Int.random(in: 0..<textLines.count, using: &rng)
        return textLines[index]
    }

    private func randomFontSize() -> CGFloat {
        let base = CGFloat(fontSize)
        let variation = base * CGFloat(fontSizeVariation)
        return base + CGFloat.random(in: -variation...variation, using: &rng)
    }

    /// Random opacity around the base value (±40% variation, clamped to 0.1-1.0)
    private func randomOpacity() -> Float {
        let variation: Float = 0.4  // ±40% of the base opacity
        let delta = opacity * variation
        let randomized = opacity + Float.random(in: -delta...delta, using: &rng)
        return max(0.1, min(1.0, randomized))  // Clamp to reasonable range
    }

    /// Random CGFloat in range using seeded RNG
    private func randomCGFloat(in range: ClosedRange<CGFloat>) -> CGFloat {
        CGFloat.random(in: range, using: &rng)
    }

    /// Random position with spatial distribution to avoid clustering
    /// Uses rejection sampling against recent position history (not just active snippets)
    private func randomPosition(for size: CGSize) -> CGPoint {
        // Allow text to go nearly to the edges (position is top-left of text)
        // Small margin to ensure at least some text is visible
        let margin: CGFloat = 10

        // X: start within left 60% of frame to leave room for wrapping
        let minX: CGFloat = margin
        let maxX = size.width * 0.60

        // Y: start within top 80% to leave room for multi-line text
        let minY: CGFloat = margin
        let maxY = size.height * 0.80

        // Minimum distance from recent positions (as fraction of screen diagonal)
        let diagonal = sqrt(size.width * size.width + size.height * size.height)
        let minDistance = diagonal * 0.20  // At least 20% of diagonal apart

        // Try to find a position that's well-separated from recent spawn points
        // Use rejection sampling with limited attempts
        for _ in 0..<30 {
            let x = randomCGFloat(in: minX...maxX)
            let y = randomCGFloat(in: minY...maxY)
            let candidate = CGPoint(x: x, y: y)

            // Check distance to all recent positions (not just active snippets)
            var tooClose = false
            for pos in recentPositions {
                let dx = candidate.x - pos.x
                let dy = candidate.y - pos.y
                let distance = sqrt(dx * dx + dy * dy)
                if distance < minDistance {
                    tooClose = true
                    break
                }
            }

            if !tooClose {
                // Record this position in history
                recordPosition(candidate)
                return candidate
            }
        }

        // Fallback: use stratified random position based on history count
        // Cycle through a 3x3 grid to ensure variety
        let gridCols = 3
        let gridRows = 3
        let cellIndex = recentPositions.count % (gridCols * gridRows)
        let col = cellIndex % gridCols
        let row = cellIndex / gridCols

        // Random position within the grid cell
        let cellWidth = (maxX - minX) / CGFloat(gridCols)
        let cellHeight = (maxY - minY) / CGFloat(gridRows)

        let cellMinX = minX + CGFloat(col) * cellWidth
        let cellMinY = minY + CGFloat(row) * cellHeight

        let x = randomCGFloat(in: cellMinX...(cellMinX + cellWidth))
        let y = randomCGFloat(in: cellMinY...(cellMinY + cellHeight))

        let position = CGPoint(x: x, y: y)
        recordPosition(position)
        return position
    }

    /// Record a spawn position in history (maintains fixed size buffer)
    private func recordPosition(_ position: CGPoint) {
        recentPositions.append(position)
        // Keep only the last N positions
        if recentPositions.count > Self.maxPositionHistory {
            recentPositions.removeFirst()
        }
    }

    // MARK: - Effect

    func apply(to image: CIImage, context: inout RenderContext) -> CIImage {
        // Trigger lazy loading on first use
        ensureTextLoaded()

        let extent = image.extent
        lastSize = extent.size

        // Update snippets - decrement duration, remove expired
        activeSnippets = activeSnippets.compactMap { snippet in
            var s = snippet
            s.framesRemaining -= 1
            return s.framesRemaining > 0 ? s : nil
        }

        // Only add snippets if we have text loaded
        guard !textLines.isEmpty else { return image }

        // Add new snippet if interval elapsed and under max
        framesSinceLastAdd += 1
        if framesSinceLastAdd >= changeIntervalFrames && activeSnippets.count < maxTextCount {
            addNewSnippet(size: extent.size)
            framesSinceLastAdd = 0
        }

        // Render text overlay
        guard !activeSnippets.isEmpty else { return image }

        return renderTextOverlay(on: image)
    }

    private func addNewSnippet(size: CGSize) {
        let text = randomLine()
        let fSize = randomFontSize()
        let snippetOpacity = randomOpacity()
        // Set wrap extension once at creation (not every frame)
        let wrapExt = randomCGFloat(in: 0...200)

        // Duration scales with text length: longer text stays longer
        // Internal 4x multiplier so user-facing multiplier of 1.0 gives reasonable duration
        // Minimum 60 frames so short text is still readable
        let baseDuration = Float(text.count) * durationMultiplier * 4.0
        let duration = max(60, Int(baseDuration))

        let snippet = TextSnippet(
            text: text,
            position: randomPosition(for: size),
            fontSize: fSize, 
            opacity: snippetOpacity,
            wrapExtension: wrapExt,
            framesRemaining: duration,
            initialDuration: duration
        )
        activeSnippets.append(snippet)
    }

    private func renderTextOverlay(on image: CIImage) -> CIImage {
        let extent = image.extent
        let width = Int(extent.width)
        let height = Int(extent.height)

        // Create bitmap context
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        // Set antialiasing mode
        context.setShouldAntialias(antialiasing)
        context.setAllowsAntialiasing(antialiasing)
        context.setShouldSmoothFonts(antialiasing)

        // Clear to fully transparent - must use setFillColor + fill, not just clear
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        context.setBlendMode(.copy)  // Overwrite, don't blend
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.normal)  // Reset for text drawing

        // Create text color from hex string
        let color = NSColor.fromHex(textColor) ?? .white

        // Draw each snippet with word wrapping
        // Allow text up to the edge with small margin
        let margin: CGFloat = 10

        for snippet in activeSnippets {
            let font = NSFont(name: fontName, size: snippet.fontSize) ?? NSFont.systemFont(ofSize: snippet.fontSize)

            // Fade in/out at edges of duration (use snippet's initial duration)
            let fadeFrames = max(1, min(20, snippet.initialDuration / 4))
            let fadeIn = min(1.0, Float(snippet.initialDuration - snippet.framesRemaining) / Float(fadeFrames))
            let fadeOut = min(1.0, Float(snippet.framesRemaining) / Float(fadeFrames))
            let alpha = snippet.opacity * fadeIn * fadeOut

            // CoreText uses bottom-left origin. Convert from top-left to bottom-left:
            // Our position.y is from top, CTFrame expects y from bottom
            // First calculate text size to know height, then flip the y coordinate

            // Calculate wrap width: from position to right edge minus margin
            // Use 90% of screen width max to allow text to use more horizontal space
            let rightEdge = CGFloat(width) - margin
            let availableWidth = max(100, rightEdge - snippet.position.x)
            let wrapWidth = min(availableWidth, CGFloat(width) * 0.9)

            // Paragraph style for wrapping
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.alignment = .left

            // Calculate text rect first (needed for both stroke and fill)
            // Skip snippets with invalid positions
            let maxHeight = CGFloat(height) - snippet.position.y - margin
            guard maxHeight > 20 else { continue }  // Skip if no room for text
            let constraints = CGSize(width: wrapWidth, height: maxHeight)

            // Base attributes for size calculation
            let baseAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraphStyle
            ]
            let baseString = NSAttributedString(string: snippet.text, attributes: baseAttrs)
            let sizeFramesetter = CTFramesetterCreateWithAttributedString(baseString)
            let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
                sizeFramesetter, CFRange(location: 0, length: 0), nil, constraints, nil
            )

            // Convert from top-left origin to bottom-left origin for CoreText
            let flippedY = CGFloat(height) - snippet.position.y - min(textSize.height, maxHeight)

            // Clamp to stay within frame - ensure valid rect
            let clampedX = max(margin, min(snippet.position.x, rightEdge - 100))
            let clampedY = max(margin, flippedY)
            let clampedWidth = min(max(10, textSize.width), wrapWidth)
            let clampedHeight = min(max(10, textSize.height), maxHeight)

            // Skip if rect would be invalid
            guard clampedWidth > 0, clampedHeight > 0,
                  clampedX >= 0, clampedY >= 0,
                  clampedX + clampedWidth <= CGFloat(width),
                  clampedY + clampedHeight <= CGFloat(height) else { continue }

            let textRect = CGRect(
                x: clampedX,
                y: clampedY,
                width: clampedWidth,
                height: clampedHeight
            )
            let path = CGPath(rect: textRect, transform: nil)

            // Draw stroke first (if enabled) - contrasting color for visibility
            if strokeWidth > 0 {
                // Use inverted/contrasting stroke color (dark stroke for light text, vice versa)
                let strokeColor = contrastingColor(for: color).withAlphaComponent(CGFloat(alpha))
                let strokeAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: strokeColor,
                    .strokeColor: strokeColor,
                    .strokeWidth: CGFloat(strokeWidth),  // Positive = stroke only
                    .paragraphStyle: paragraphStyle
                ]
                let strokeString = NSAttributedString(string: snippet.text, attributes: strokeAttrs)
                let strokeFramesetter = CTFramesetterCreateWithAttributedString(strokeString)
                let strokeFrame = CTFramesetterCreateFrame(
                    strokeFramesetter, CFRange(location: 0, length: 0), path, nil
                )
                context.saveGState()
                CTFrameDraw(strokeFrame, context)
                context.restoreGState()
            }

            // Draw fill on top
            let fillAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color.withAlphaComponent(CGFloat(alpha)),
                .paragraphStyle: paragraphStyle
            ]
            let fillString = NSAttributedString(string: snippet.text, attributes: fillAttrs)
            let fillFramesetter = CTFramesetterCreateWithAttributedString(fillString)
            let fillFrame = CTFramesetterCreateFrame(
                fillFramesetter, CFRange(location: 0, length: 0), path, nil
            )
            context.saveGState()
            CTFrameDraw(fillFrame, context)
            context.restoreGState()
        }

        // Convert to CIImage and composite
        guard let cgImage = context.makeImage() else { return image }
        let textImage = CIImage(cgImage: cgImage)

        // Composite text over original
        return textImage.composited(over: image)
    }

    func reset() {
        activeSnippets.removeAll()
        recentPositions.removeAll()
        framesSinceLastAdd = 0
        // Mark as not loaded so next use will reload (picks up new files)
        hasLoaded = false
        isLoading = false
    }

    func copy() -> Effect {
        // Pass the same seed so the copy produces identical random sequences
        TextOverlayEffect(fontSize: fontSize, fontSizeVariation: fontSizeVariation, opacity: opacity,
                        maxTextCount: maxTextCount, changeIntervalFrames: changeIntervalFrames,
                        durationMultiplier: durationMultiplier, fontName: fontName,
                        textColor: textColor, strokeWidth: strokeWidth,
                        antialiasing: antialiasing, randomSeed: randomSeed)
    }

    /// Generate a contrasting color for text stroke (dark for light colors, light for dark)
    private func contrastingColor(for color: NSColor) -> NSColor {
        // Get RGB components (converting to sRGB if needed)
        guard let rgbColor = color.usingColorSpace(.sRGB) else {
            return .black
        }
        let r = rgbColor.redComponent
        let g = rgbColor.greenComponent
        let b = rgbColor.blueComponent

        // Calculate perceived brightness (ITU-R BT.709)
        let brightness = 0.2126 * r + 0.7152 * g + 0.0722 * b

        // Return dark for light colors, light for dark colors
        return brightness > 0.5 ? NSColor(white: 0.1, alpha: 1.0) : NSColor(white: 0.9, alpha: 1.0)
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

