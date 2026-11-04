import Cocoa

extension AppSettings {
    // MARK: - Recording

    /// When true, a pane whose visible terminal is recording gets a red outline.
    var highlightRecordingPane: Bool {
        get { bool(K.highlightRecordingPane, default: true) }
        set { set(newValue, forKey: K.highlightRecordingPane, topic: .layout) }
    }

    var recordingStopAction: RecordingStopAction {
        get {
            guard UserDefaults.standard.object(forKey: K.recordingStopAction) != nil else { return .toast }
            return RecordingStopAction(rawValue: UserDefaults.standard.integer(forKey: K.recordingStopAction))
                ?? .toast
        }
        set { set(newValue.rawValue, forKey: K.recordingStopAction, topic: .layout) }
    }

    /// Where new `.cast` recordings go. Empty means `~/.boo/recordings`.
    var recordingsFolder: String {
        get { UserDefaults.standard.string(forKey: K.recordingsFolder) ?? "" }
        set { set(newValue, forKey: K.recordingsFolder, topic: .layout) }
    }

    /// File name for new recordings; see `SessionRecorder.fileName` for the tokens.
    var recordingFileNameTemplate: String {
        get {
            let raw = UserDefaults.standard.string(forKey: K.recordingFileNameTemplate) ?? ""
            return raw.trimmingCharacters(in: .whitespaces).isEmpty ? SessionRecorder.defaultTemplate : raw
        }
        set { set(newValue, forKey: K.recordingFileNameTemplate, topic: .layout) }
    }

    /// Longest pause kept on playback, written as the cast's `idle_time_limit`.
    /// 0 keeps pauses as recorded.
    var recordingIdleTimeLimit: Double {
        get {
            guard UserDefaults.standard.object(forKey: K.recordingIdleTimeLimit) != nil else { return 2 }
            return max(0, UserDefaults.standard.double(forKey: K.recordingIdleTimeLimit))
        }
        set { set(max(0, newValue), forKey: K.recordingIdleTimeLimit, topic: .layout) }
    }

    // MARK: - Tabs

    /// Default content type for new tabs (terminal, browser, etc.).
    var defaultTabType: ContentType {
        get {
            guard let raw = UserDefaults.standard.string(forKey: K.defaultTabType) else { return .terminal }
            return ContentType(rawValue: raw) ?? .terminal
        }
        set { set(newValue.rawValue, forKey: K.defaultTabType, topic: .layout) }
    }

    /// When true, auto-detect content type from pasted URLs/file paths.
    var autoDetectContentType: Bool {
        get { bool(K.autoDetectContentType, default: true) }
        set { set(newValue, forKey: K.autoDetectContentType, topic: .layout) }
    }

    /// How to open markdown files from the file tree.
    var markdownOpenMode: MarkdownOpenMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: K.markdownOpenMode) else { return .preview }
            return MarkdownOpenMode(rawValue: raw) ?? .preview
        }
        set { set(newValue.rawValue, forKey: K.markdownOpenMode, topic: .explorer) }
    }

    // MARK: - Browser

    var linkOpenMode: LinkOpenMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: K.linkOpenMode) else { return .browserTab }
            return LinkOpenMode(rawValue: raw) ?? .browserTab
        }
        set { set(newValue.rawValue, forKey: K.linkOpenMode, topic: .layout) }
    }

    var browserHomePage: String {
        get { UserDefaults.standard.string(forKey: K.browserHomePage) ?? "https://google.com" }
        set { set(newValue, forKey: K.browserHomePage, topic: .layout) }
    }

    var browserPersistentWebsiteDataEnabled: Bool {
        get { bool(K.browserPersistentWebsiteDataEnabled, default: false) }
        set { set(newValue, forKey: K.browserPersistentWebsiteDataEnabled, topic: .layout) }
    }

    /// When true, closing a browser tab asks first (a page can hold unsent form input).
    var browserConfirmClose: Bool {
        get { bool(K.browserConfirmClose, default: true) }
        set { set(newValue, forKey: K.browserConfirmClose, topic: .layout) }
    }

    var browserHistoryEnabled: Bool {
        get { bool(K.browserHistoryEnabled, default: true) }
        set { set(newValue, forKey: K.browserHistoryEnabled, topic: .layout) }
    }

    /// Maximum number of history entries to keep.
    var browserHistoryLimit: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: K.browserHistoryLimit)
            return v > 0 ? v : 5000
        }
        set { set(newValue, forKey: K.browserHistoryLimit, topic: .layout) }
    }

    // MARK: - Editor

    var editorFontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: K.editorFontSize)
            return v > 0 ? CGFloat(v) : 13.0
        }
        set { set(Double(newValue), forKey: K.editorFontSize, topic: .editor) }
    }

    var editorFontName: String {
        get { UserDefaults.standard.string(forKey: K.editorFontName) ?? "SF Mono" }
        set { set(newValue, forKey: K.editorFontName, topic: .editor) }
    }

    func resolvedEditorFont() -> NSFont {
        if let font = NSFont(name: editorFontName, size: editorFontSize) { return font }
        return NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    }

    var editorTabSize: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: K.editorTabSize)
            return v > 0 ? v : 4
        }
        set { set(newValue, forKey: K.editorTabSize, topic: .editor) }
    }

    var editorInsertSpaces: Bool {
        get { bool(K.editorInsertSpaces, default: true) }
        set { set(newValue, forKey: K.editorInsertSpaces, topic: .editor) }
    }

    var editorWordWrap: Bool {
        get { bool(K.editorWordWrap, default: false) }
        set { set(newValue, forKey: K.editorWordWrap, topic: .editor) }
    }

    var editorLineNumbers: Bool {
        get { bool(K.editorLineNumbers, default: true) }
        set { set(newValue, forKey: K.editorLineNumbers, topic: .editor) }
    }

    var editorMinimap: Bool {
        get { bool(K.editorMinimap, default: false) }
        set { set(newValue, forKey: K.editorMinimap, topic: .editor) }
    }

    var editorFormatOnSave: Bool {
        get { bool(K.editorFormatOnSave, default: false) }
        set { set(newValue, forKey: K.editorFormatOnSave, topic: .editor) }
    }

    var editorRulerColumn: Int {
        get { UserDefaults.standard.integer(forKey: K.editorRulerColumn) }
        set { set(newValue, forKey: K.editorRulerColumn, topic: .editor) }
    }

    /// Lets a file's own indentation win over tab size and insert spaces.
    var editorDetectIndentation: Bool {
        get { bool(K.editorDetectIndentation, default: true) }
        set { set(newValue, forKey: K.editorDetectIndentation, topic: .editor) }
    }

    var editorRenderWhitespace: EditorRenderWhitespace {
        get {
            UserDefaults.standard.string(forKey: K.editorRenderWhitespace).flatMap(EditorRenderWhitespace.init)
                ?? .selection
        }
        set { set(newValue.rawValue, forKey: K.editorRenderWhitespace, topic: .editor) }
    }

    var editorBracketPairColors: Bool {
        get { bool(K.editorBracketPairColors, default: true) }
        set { set(newValue, forKey: K.editorBracketPairColors, topic: .editor) }
    }

    var editorStickyScroll: Bool {
        get { bool(K.editorStickyScroll, default: false) }
        set { set(newValue, forKey: K.editorStickyScroll, topic: .editor) }
    }

    var editorFontLigatures: Bool {
        get { bool(K.editorFontLigatures, default: false) }
        set { set(newValue, forKey: K.editorFontLigatures, topic: .editor) }
    }

    var editorCursorStyle: EditorCursorStyle {
        get { UserDefaults.standard.string(forKey: K.editorCursorStyle).flatMap(EditorCursorStyle.init) ?? .line }
        set { set(newValue.rawValue, forKey: K.editorCursorStyle, topic: .editor) }
    }

    var editorCursorBlinking: Bool {
        get { bool(K.editorCursorBlinking, default: true) }
        set { set(newValue, forKey: K.editorCursorBlinking, topic: .editor) }
    }

    var editorAutosave: EditorAutosave {
        get { UserDefaults.standard.string(forKey: K.editorAutosave).flatMap(EditorAutosave.init) ?? .off }
        set { set(newValue.rawValue, forKey: K.editorAutosave, topic: .editor) }
    }

    /// Reload a file changed on disk; asks first when the tab has unsaved edits.
    var editorReloadOnExternalChange: Bool {
        get { bool(K.editorReloadOnExternalChange, default: true) }
        set { set(newValue, forKey: K.editorReloadOnExternalChange, topic: .editor) }
    }

    var editorShowStatusStrip: Bool {
        get { bool(K.editorShowStatusStrip, default: true) }
        set { set(newValue, forKey: K.editorShowStatusStrip, topic: .editor) }
    }

    var editorTrimTrailingWhitespace: Bool {
        get { bool(K.editorTrimTrailingWhitespace, default: false) }
        set { set(newValue, forKey: K.editorTrimTrailingWhitespace, topic: .editor) }
    }

    var editorInsertFinalNewline: Bool {
        get { bool(K.editorInsertFinalNewline, default: false) }
        set { set(newValue, forKey: K.editorInsertFinalNewline, topic: .editor) }
    }
}
