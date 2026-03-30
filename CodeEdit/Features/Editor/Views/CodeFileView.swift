//
//  CodeFileView.swift
//  CodeEditModules/CodeFile
//
//  Created by Marco Carnevali on 17/03/22.
//

import Foundation
import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages
import Combine

/// CodeFileView is just a wrapper of the `CodeEditor` dependency
struct CodeFileView: View {
    /// The editor instance for this view. Not observed - we only read static properties from it.
    /// State like cursorPositions and scrollPosition is managed through the StateHolder binding.
    private var editorInstance: EditorInstance
    @ObservedObject private var codeFile: CodeFileDocument

    /// Any coordinators passed to the view.
    private var textViewCoordinators: [TextViewCoordinator]
    private var highlightProviders: [any HighlightProviding] = []

    @AppSettings(\.textEditing.defaultTabWidth)
    var defaultTabWidth
    @AppSettings(\.textEditing.indentOption)
    var indentOption
    @AppSettings(\.textEditing.lineHeightMultiple)
    var lineHeightMultiple
    @AppSettings(\.textEditing.wrapLinesToEditorWidth)
    var wrapLinesToEditorWidth
    @AppSettings(\.textEditing.overscroll)
    var overscroll
    @AppSettings(\.textEditing.font)
    var settingsFont
    @AppSettings(\.theme.useThemeBackground)
    var useThemeBackground
    @AppSettings(\.theme.matchAppearance)
    var matchAppearance
    @AppSettings(\.textEditing.letterSpacing)
    var letterSpacing
    @AppSettings(\.textEditing.bracketEmphasis)
    var bracketEmphasis
    @AppSettings(\.textEditing.useSystemCursor)
    var useSystemCursor
    @AppSettings(\.textEditing.showGutter)
    var showGutter
    @AppSettings(\.textEditing.showMinimap)
    var showMinimap
    @AppSettings(\.textEditing.showFoldingRibbon)
    var showFoldingRibbon
    @AppSettings(\.textEditing.reformatAtColumn)
    var reformatAtColumn
    @AppSettings(\.textEditing.showReformattingGuide)
    var showReformattingGuide
    @AppSettings(\.textEditing.invisibleCharacters)
    var invisibleCharactersConfiguration
    @AppSettings(\.textEditing.warningCharacters)
    var warningCharacters

    @Environment(\.colorScheme)
    private var colorScheme

    @EnvironmentObject var undoRegistration: UndoManagerRegistration

    @ObservedObject private var themeModel: ThemeModel = .shared

    private var cancellables = Set<AnyCancellable>()

    private let isEditable: Bool

    init(
        editorInstance: EditorInstance,
        codeFile: CodeFileDocument,
        textViewCoordinators: [TextViewCoordinator] = [],
        isEditable: Bool = true
    ) {
        self.editorInstance = editorInstance
        self._codeFile = .init(wrappedValue: codeFile)
        // Initialize the state holder to break SwiftUI observation of editorInstance's @Published properties.
        self._stateHolder = State(initialValue: StateHolder(editorInstance: editorInstance))

        self.textViewCoordinators = textViewCoordinators
            + [editorInstance.rangeTranslator]
            + [codeFile.contentCoordinator]
            + [codeFile.languageServerObjects.textCoordinator]
        self.isEditable = isEditable

        if let openOptions = codeFile.openOptions {
                codeFile.openOptions = nil
                editorInstance.cursorPositions = openOptions.cursorPositions
        }

        highlightProviders = [codeFile.languageServerObjects.highlightProvider] + [codeFile.treeSitterClient]

        codeFile
            .contentCoordinator
            .textUpdatePublisher
            .sink { [weak codeFile] _ in
                codeFile?.updateChangeCount(.changeDone)
            }
            .store(in: &cancellables)
    }

    private var currentTheme: Theme {
        themeModel.selectedTheme ?? themeModel.themes.first!
    }

    @State private var font: NSFont = Settings[\.textEditing].font.current

    @Environment(\.edgeInsets)
    private var edgeInsets

    /// Wrapper class that holds the state and breaks SwiftUI observation.
    /// Using a class wrapper prevents SwiftUI from tracking the editorInstance's @Published properties.
    private final class StateHolder {
        weak var editorInstance: EditorInstance?

        init(editorInstance: EditorInstance) {
            self.editorInstance = editorInstance
        }

        func getState() -> SourceEditorState {
            guard let editorInstance else {
                return SourceEditorState()
            }
            return SourceEditorState(
                cursorPositions: editorInstance.cursorPositions,
                scrollPosition: editorInstance.scrollPosition,
                findText: editorInstance.findText,
                replaceText: editorInstance.replaceText
            )
        }

        func setState(_ newState: SourceEditorState) {
            guard let editorInstance else { return }
            // Update synchronously to avoid scroll jitter.
            // The SourceEditor coordinator already defers calls to this setter,
            // so we should be outside of SwiftUI's view update phase.
            if editorInstance.cursorPositions != (newState.cursorPositions ?? []) {
                editorInstance.cursorPositions = newState.cursorPositions ?? []
            }
            if editorInstance.scrollPosition != newState.scrollPosition {
                editorInstance.scrollPosition = newState.scrollPosition
            }
            if editorInstance.findText != newState.findText {
                editorInstance.findText = newState.findText
                editorInstance.findTextSubject.send(newState.findText)
            }
            if editorInstance.replaceText != newState.replaceText {
                editorInstance.replaceText = newState.replaceText
                editorInstance.replaceTextSubject.send(newState.replaceText)
            }
        }
    }

    /// Holds a reference to the editorInstance without triggering SwiftUI observation.
    @State private var stateHolder: StateHolder

    /// Creates a binding that reads/writes to editorInstance properties through the StateHolder.
    /// The StateHolder breaks SwiftUI observation to avoid the "Publishing changes from within view updates" warning.
    private var editorStateBinding: Binding<SourceEditorState> {
        Binding(
            get: { stateHolder.getState() },
            set: { newState in stateHolder.setState(newState) }
        )
    }

    var body: some View {
        SourceEditor(
            codeFile.content ?? NSTextStorage(),
            language: codeFile.getLanguage(),
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: currentTheme.editor.editorTheme,
                    useThemeBackground: useThemeBackground,
                    font: font,
                    lineHeightMultiple: lineHeightMultiple,
                    letterSpacing: letterSpacing,
                    wrapLines: wrapLinesToEditorWidth,
                    useSystemCursor: useSystemCursor,
                    tabWidth: defaultTabWidth,
                    bracketPairEmphasis: getBracketPairEmphasis()
                ),
                behavior: .init(
                    isEditable: isEditable,
                    indentOption: indentOption.textViewOption(),
                    reformatAtColumn: reformatAtColumn
                ),
                layout: .init(
                    editorOverscroll: overscroll.overscrollPercentage,
                    contentInsets: edgeInsets.nsEdgeInsets,
                    additionalTextInsets: NSEdgeInsets(top: 2, left: 0, bottom: 0, right: 0)
                ),
                peripherals: .init(
                    showGutter: showGutter,
                    showMinimap: showMinimap,
                    showReformattingGuide: showReformattingGuide,
                    showFoldingRibbon: showFoldingRibbon,
                    invisibleCharactersConfiguration: invisibleCharactersConfiguration.textViewOption(),
                    warningCharacters: Set(warningCharacters.characters.keys)
                )
            ),
            state: editorStateBinding,
            highlightProviders: highlightProviders,
            undoManager: undoRegistration.manager(forFile: editorInstance.file),
            coordinators: textViewCoordinators
        )
        // This view needs to refresh when the codefile changes. The file URL is too stable.
        .id(ObjectIdentifier(codeFile))
        .background {
            if colorScheme == .dark {
                EffectView(.underPageBackground)
            } else {
                EffectView(.contentBackground)
            }
        }
        .colorScheme(currentTheme.appearance == .dark ? .dark : .light)
        // minHeight zero fixes a bug where the app would freeze if the contents of the file are empty.
        .frame(minHeight: .zero, maxHeight: .infinity)
        .onChange(of: settingsFont) { _, newFontSetting in
            font = newFontSetting.current
        }
        .onChange(of: editorInstance) { _, newInstance in
            // Update the stateHolder to point to the new editorInstance.
            // This is necessary because @State doesn't reset when the view is updated with new parameters.
            stateHolder = StateHolder(editorInstance: newInstance)
        }
    }

    /// Determines the style of bracket emphasis based on the `bracketEmphasis` setting and the current theme.
    /// - Returns: The emphasis style to use for bracket pair emphasis.
    private func getBracketPairEmphasis() -> BracketPairEmphasis? {
        let color = if Settings[\.textEditing].bracketEmphasis.useCustomColor {
            Settings[\.textEditing].bracketEmphasis.color.nsColor
        } else {
            currentTheme.editor.text.nsColor.withAlphaComponent(0.8)
        }

        switch Settings[\.textEditing].bracketEmphasis.highlightType {
        case .disabled:
            return nil
        case .flash:
            return .flash
        case .bordered:
            return .bordered(color: color)
        case .underline:
            return .underline(color: color)
        }
    }
}

// This extension is kept here because it should not be used elsewhere in the app and may cause confusion
// due to the similar type name from the CETV module.
private extension SettingsData.TextEditingSettings.IndentOption {
    func textViewOption() -> IndentOption {
        switch self.indentType {
        case .spaces:
            return IndentOption.spaces(count: spaceCount)
        case .tab:
            return IndentOption.tab
        }
    }
}

private extension SettingsData.TextEditingSettings.InvisibleCharactersConfig {
    func textViewOption() -> InvisibleCharactersConfiguration {
        guard self.enabled else { return .empty }
        var config = InvisibleCharactersConfiguration(
            showSpaces: self.showSpaces,
            showTabs: self.showTabs,
            showLineEndings: self.showLineEndings
        )

        config.spaceReplacement = self.spaceReplacement
        config.tabReplacement = self.tabReplacement
        config.carriageReturnReplacement = self.carriageReturnReplacement
        config.lineFeedReplacement = self.lineFeedReplacement
        config.paragraphSeparatorReplacement = self.paragraphSeparatorReplacement
        config.lineSeparatorReplacement = self.lineSeparatorReplacement

        return config
    }
}
