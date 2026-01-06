//
//  TextFieldFocusMonitor.swift
//  HypnoAppShell
//
//  Monitors text field editing state using AppKit notifications.
//  This is the bulletproof solution - works for ALL text fields automatically
//  without requiring per-field wiring.
//
//  Use: Disable single-key shortcuts when isEditing == true
//

import Foundation
import AppKit
import Combine

/// Monitors when any text field in the app starts/ends editing.
/// Uses NSText notifications which fire for all TextField/TextEditor controls.
@MainActor
public final class TextFieldFocusMonitor: ObservableObject {
    
    /// True when any text field is being edited
    @Published public private(set) var isEditing: Bool = false
    
    private var beginObservers: [NSObjectProtocol] = []
    private var endObservers: [NSObjectProtocol] = []
    private var activeEditorCount: Int = 0
    
    public init() {
        let center = NotificationCenter.default

        beginObservers = [
            center.addObserver(
                forName: NSText.didBeginEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.beginEditing()
                }
            },
            center.addObserver(
                forName: NSControl.textDidBeginEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.beginEditing()
                }
            }
        ]

        endObservers = [
            center.addObserver(
                forName: NSText.didEndEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.endEditing()
                }
            },
            center.addObserver(
                forName: NSControl.textDidEndEditingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.endEditing()
                }
            }
        ]
    }
    
    deinit {
        for observer in beginObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for observer in endObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func beginEditing() {
        activeEditorCount += 1
        if !isEditing {
            isEditing = true
        }
    }

    private func endEditing() {
        activeEditorCount = max(activeEditorCount - 1, 0)
        if activeEditorCount == 0 && isEditing {
            isEditing = false
        }
    }
}
