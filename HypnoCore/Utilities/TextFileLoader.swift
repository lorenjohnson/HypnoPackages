//
//  TextFileLoader.swift
//  HypnoCore
//
//  Utility for loading and parsing text files from disk.
//  Supports plain text, RTF, RTFD, and Markdown formats.
//

import Foundation
import AppKit

/// Utility class for loading text content from files on disk.
/// Handles plain text, RTF, RTFD, and Markdown formats with automatic parsing.
public final class TextFileLoader {

    // MARK: - Configuration

    /// Maximum number of files to load
    public var maxFiles: Int

    /// Maximum file size in bytes
    public var maxFileSize: Int

    /// Maximum total lines to return
    public var maxTotalLines: Int

    // MARK: - Init

    public init(maxFiles: Int = 100, maxFileSize: Int = 100_000, maxTotalLines: Int = 1000) {
        self.maxFiles = maxFiles
        self.maxFileSize = maxFileSize
        self.maxTotalLines = maxTotalLines
    }

    // MARK: - Public API

    /// Load text lines from all files in a directory (recursively).
    /// Returns an array of text blocks suitable for display.
    public func loadTextLines(from directory: URL) -> [String] {
        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Recursively find all files (with limit)
        let allFiles = findAllFiles(in: directory)

        if allFiles.isEmpty {
            return ["No files found", "Add text files to:", directory.path]
        }

        var loadedLines: [String] = []

        // Try to read each file as text (any extension)
        for file in allFiles {
            guard loadedLines.count < maxTotalLines else { break }

            if let content = readAsText(file) {
                // Split into text blocks, preferring natural break points
                let blocks = splitIntoBlocks(content)
                if blocks.isEmpty {
                    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        loadedLines.append(trimmed)
                    }
                } else {
                    let remaining = maxTotalLines - loadedLines.count
                    loadedLines.append(contentsOf: blocks.prefix(remaining))
                }
            }
        }

        if loadedLines.isEmpty {
            loadedLines = ["No readable text found"]
        }

        return loadedLines
    }

    // MARK: - File Discovery

    /// Recursively find all files in a directory (with limits)
    public func findAllFiles(in directory: URL) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return files
        }

        for case let fileURL as URL in enumerator {
            guard files.count < maxFiles else { break }

            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if resourceValues.isRegularFile == true {
                    // Skip files that are too large
                    if let size = resourceValues.fileSize, size <= maxFileSize {
                        files.append(fileURL)
                    }
                }
            } catch {
                // Skip files we can't read properties for
            }
        }
        return files
    }

    // MARK: - File Reading

    /// Try to read a file as text - handles RTF, Markdown, and plain text
    public func readAsText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Quick binary check: look for null bytes (common in binary files)
        if data.contains(0) {
            return nil
        }

        let ext = url.pathExtension.lowercased()

        // RTF: Use NSAttributedString to extract plain text
        if ext == "rtf" || ext == "rtfd" {
            return parseRTF(data: data)
        }

        // Get raw text content
        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Markdown: Strip formatting
        if ext == "md" || ext == "markdown" {
            return parseMarkdown(content)
        }

        return content
    }

    // MARK: - Parsing

    /// Parse RTF to plain text using NSAttributedString
    public func parseRTF(data: Data) -> String? {
        // Try RTF first, then RTFD
        if let attrString = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return attrString.string
        }

        if let attrString = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil
        ) {
            return attrString.string
        }

        return nil
    }

    /// Split text content into display blocks at line breaks or periods
    public func splitIntoBlocks(_ content: String) -> [String] {
        // First split by any newlines
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Then split each line at periods
        return lines.flatMap { splitAtPeriods($0) }
    }

    /// Split text at periods
    public func splitAtPeriods(_ text: String) -> [String] {
        var blocks: [String] = []
        var current = ""

        for char in text {
            current.append(char)

            if char == "." {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    blocks.append(trimmed)
                }
                current = ""
            }
        }

        // Add any remaining text
        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            blocks.append(remaining)
        }

        return blocks.isEmpty ? [text] : blocks
    }

    /// Strip markdown formatting to plain text
    public func parseMarkdown(_ content: String) -> String {
        var text = content

        // Remove code blocks (``` ... ```)
        text = text.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: "",
            options: .regularExpression
        )

        // Remove inline code (`...`)
        text = text.replacingOccurrences(
            of: "`([^`]+)`",
            with: "$1",
            options: .regularExpression
        )

        // Remove headers (# ## ### etc) - keep the text
        text = text.replacingOccurrences(
            of: "^#{1,6}\\s*",
            with: "",
            options: .regularExpression
        )

        // Remove bold/italic (**text**, *text*, __text__, _text_)
        text = text.replacingOccurrences(
            of: "[*_]{1,2}([^*_]+)[*_]{1,2}",
            with: "$1",
            options: .regularExpression
        )

        // Remove links [text](url) -> text
        text = text.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^)]+\\)",
            with: "$1",
            options: .regularExpression
        )

        // Remove images ![alt](url)
        text = text.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\([^)]+\\)",
            with: "",
            options: .regularExpression
        )

        // Remove horizontal rules (---, ***, ___)
        text = text.replacingOccurrences(
            of: "^[-*_]{3,}$",
            with: "",
            options: .regularExpression
        )

        // Remove blockquotes (> )
        text = text.replacingOccurrences(
            of: "^>\\s*",
            with: "",
            options: .regularExpression
        )

        // Remove list markers (- , * , 1. )
        text = text.replacingOccurrences(
            of: "^[\\-*]\\s+",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "^\\d+\\.\\s+",
            with: "",
            options: .regularExpression
        )

        return text
    }
}
