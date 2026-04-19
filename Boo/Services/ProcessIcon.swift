import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Maps foreground process names to SF Symbol icons and display labels.
/// Used by tab bar, status bar, and plugin when-clause matching.
enum ProcessIcon {
    /// Returns an SF Symbol name for a known process, or nil for unknown/shell processes.
    static func icon(for process: String) -> String? {
        let name = process.lowercased()
        return iconMap[name]
    }

    /// Returns a short display label for the process (e.g. "Node" for "node").
    static func displayName(for process: String) -> String? {
        let name = process.lowercased()
        return displayMap[name]
    }

    /// Process category for plugin when-clause matching.
    /// e.g. "editor", "runtime", "tool", "shell", "network"
    static func category(for process: String) -> String? {
        let name = process.lowercased()
        return categoryMap[name]
    }

    /// Whether this process is a shell (should be transparent in tabs).
    static func isShell(_ process: String) -> Bool {
        shells.contains(process.lowercased())
    }

    #if canImport(AppKit)
        /// Returns a custom NSImage for processes that have a dedicated icon asset, or nil to fall
        /// back to the SF Symbol returned by `icon(for:)`. The image is tinted to the given color.
        static func customImage(for process: String, color: NSColor, size: CGFloat) -> NSImage? {
            let name = process.lowercased()
            guard let assetName = customAssetMap[name] else { return nil }
            guard
                let url = BooResourceBundle.bundle.url(
                    forResource: assetName, withExtension: "pdf", subdirectory: "Images"),
                let img = NSImage(contentsOf: url)
            else { return nil }
            img.isTemplate = true
            let targetSize = NSSize(width: size, height: size)
            let tinted = NSImage(size: targetSize, flipped: false) { rect in
                img.draw(
                    in: rect, from: NSRect(origin: .zero, size: img.size),
                    operation: .sourceOver, fraction: 1.0)
                color.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            return tinted
        }

        private static let customAssetMap: [String: String] = [
            "claude": "claude-icon"
        ]

        /// Fixed brand colors for specific processes, bypassing theme palette.
        private static let fixedColorMap: [String: NSColor] = [
            "claude": NSColor(red: 0xD7 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1.0)
        ]
    #endif

    #if canImport(AppKit)
        /// Returns a theme-appropriate color for the process icon.
        /// Colors are derived from the terminal theme's ANSI palette and chrome colors.
        static func themeColor(for process: String, theme: TerminalTheme, isActive: Bool) -> NSColor {
            guard isActive else { return theme.chromeMuted }
            if let fixed = fixedColorMap[process.lowercased()] { return fixed }
            let cat = category(for: process)
            switch cat {
            case "editor":
                // Green — creative/productive
                return theme.ansiColors[2].nsColor
            case "vcs":
                // Orange/yellow — branch/merge
                return theme.ansiColors[3].nsColor
            case "runtime":
                // Cyan — execution
                return theme.ansiColors[6].nsColor
            case "build", "package":
                // Yellow — building
                return theme.ansiColors[3].nsColor
            case "container":
                // Blue — infrastructure
                return theme.ansiColors[4].nsColor
            case "network":
                // Magenta — remote
                return theme.ansiColors[5].nsColor
            case "monitor":
                // Red — attention/performance
                return theme.ansiColors[1].nsColor
            case "database":
                // Blue — data
                return theme.ansiColors[4].nsColor
            case "filemanager":
                // Accent — navigation
                return theme.accentColor
            case "multiplexer":
                // Magenta — session management
                return theme.ansiColors[5].nsColor
            case "ai":
                // Bright magenta — AI/LLM
                return theme.ansiColors[13].nsColor
            default:
                // Accent for known processes, muted for unknown
                return icon(for: process) != nil ? theme.accentColor : theme.chromeMuted
            }
        }
    #endif

    /// Match a terminal title against known app title patterns.
    /// Returns a canonical process name (key into iconMap) or nil.
    static func matchTitle(_ title: String) -> String? {
        // Strip leading emoji/symbols/spinners to get the text content
        let stripped = String(
            title.drop { !$0.isLetter && !$0.isNumber }
        ).trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = titleMap[stripped] { return exact }

        // AI agents update their title dynamically (e.g. "⠂ General coding assistance").
        // Match titles that start with known spinner/status characters used by AI CLIs.
        // Check the stripped text for known agent keywords before defaulting to claude.
        if let first = title.unicodeScalars.first, Self.isAISpinnerScalar(first) {
            return "claude"
        }
        return nil
    }

    /// Maps cleaned terminal titles to canonical process names.
    private static let titleMap: [String: String] = [
        "claude code": "claude",
        "cursor": "cursor"
    ]

    /// Braille pattern dots (U+2800..U+28FF) or ✳ (U+2733) — used by AI CLI spinners.
    private static func isAISpinnerScalar(_ s: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(s.value) || s.value == 0x2733
    }

    // MARK: - Mappings

    static let shells: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "elvish", "xonsh"
    ]

    private static let iconMap: [String: String] = [
        // Editors
        "vim": "pencil.line",
        "nvim": "pencil.line",
        "neovim": "pencil.line",
        "vi": "pencil.line",
        "nano": "pencil.line",
        "emacs": "pencil.line",
        "helix": "pencil.line",
        "hx": "pencil.line",
        "micro": "pencil.line",
        "code": "chevron.left.forwardslash.chevron.right",
        "cursor": "chevron.left.forwardslash.chevron.right",

        // Git tools
        "git": "arrow.triangle.branch",
        "lazygit": "arrow.triangle.branch",
        "tig": "arrow.triangle.branch",
        "gh": "arrow.triangle.branch",

        // Runtimes & interpreters
        "node": "circle.hexagongrid",
        "deno": "circle.hexagongrid",
        "bun": "circle.hexagongrid",
        "python": "chevron.left.forwardslash.chevron.right",
        "python3": "chevron.left.forwardslash.chevron.right",
        "ruby": "diamond",
        "irb": "diamond",
        "php": "chevron.left.forwardslash.chevron.right",
        "lua": "moon",
        "luajit": "moon",
        "swift": "swift",
        "swiftc": "swift",
        "cargo": "shippingbox",
        "rustc": "shippingbox",
        "go": "chevron.left.forwardslash.chevron.right",
        "java": "cup.and.saucer",
        "kotlin": "chevron.left.forwardslash.chevron.right",
        "elixir": "drop",
        "iex": "drop",
        "erl": "drop",

        // Build tools
        "make": "hammer",
        "cmake": "hammer",
        "ninja": "hammer",
        "gradle": "hammer",
        "mvn": "hammer",
        "npm": "shippingbox",
        "yarn": "shippingbox",
        "pnpm": "shippingbox",
        "pip": "shippingbox",
        "pip3": "shippingbox",
        "brew": "mug",
        "apt": "shippingbox",
        "apt-get": "shippingbox",
        "zig": "hammer",

        // System tools
        "top": "gauge.with.dots.needle.33percent",
        "htop": "gauge.with.dots.needle.33percent",
        "btop": "gauge.with.dots.needle.33percent",
        "glances": "gauge.with.dots.needle.33percent",
        "ps": "list.bullet",

        // Network
        "ssh": "network",
        "curl": "network",
        "wget": "network",
        "ping": "network",
        "nc": "network",
        "nmap": "network",
        "telnet": "network",

        // Docker & containers
        "docker": "shippingbox",
        "docker-compose": "shippingbox",
        "podman": "shippingbox",
        "kubectl": "cloud",
        "k9s": "cloud",
        "helm": "cloud",
        "terraform": "cloud",

        // File management
        "less": "doc.text",
        "more": "doc.text",
        "cat": "doc.text",
        "bat": "doc.text",
        "head": "doc.text",
        "tail": "doc.text",
        "find": "magnifyingglass",
        "rg": "magnifyingglass",
        "grep": "magnifyingglass",
        "fd": "magnifyingglass",
        "fzf": "magnifyingglass",
        "ag": "magnifyingglass",

        // TUI apps
        "lazydocker": "shippingbox",
        "ranger": "folder",
        "yazi": "folder",
        "lf": "folder",
        "nnn": "folder",
        "mc": "folder",
        "tmux": "rectangle.split.2x1",
        "screen": "rectangle.split.2x1",
        "zellij": "rectangle.split.2x1",

        // Database
        "psql": "cylinder",
        "mysql": "cylinder",
        "sqlite3": "cylinder",
        "redis-cli": "cylinder",
        "mongosh": "cylinder",
        "mongo": "cylinder",

        // AI coding assistants
        "claude": "sparkles",
        "aider": "sparkles",
        "copilot": "sparkles",
        "cody": "sparkles",
        "continue": "sparkles",
        "cursor-cli": "sparkles",
        "goose": "sparkles",
        "mentat": "sparkles",
        "gpt": "sparkles",
        "ollama": "sparkles",
        "llm": "sparkles",
        "sgpt": "sparkles",
        "tgpt": "sparkles",
        "mods": "sparkles",
        "fabric": "sparkles",

        // Misc
        "man": "book",
        "info": "book",
        "watch": "clock",
        "sleep": "clock"
    ]

    private static let displayMap: [String: String] = [
        "nvim": "Neovim",
        "vim": "Vim",
        "vi": "Vi",
        "hx": "Helix",
        "helix": "Helix",
        "node": "Node.js",
        "deno": "Deno",
        "bun": "Bun",
        "python": "Python",
        "python3": "Python",
        "ruby": "Ruby",
        "irb": "Ruby",
        "php": "PHP",
        "lua": "Lua",
        "luajit": "LuaJIT",
        "cargo": "Cargo",
        "rustc": "Rust",
        "go": "Go",
        "java": "Java",
        "lazygit": "LazyGit",
        "lazydocker": "LazyDocker",
        "k9s": "K9s",
        "kubectl": "kubectl",
        "docker-compose": "Compose",
        "psql": "PostgreSQL",
        "mysql": "MySQL",
        "sqlite3": "SQLite",
        "redis-cli": "Redis",
        "mongosh": "MongoDB",
        "gh": "GitHub CLI",
        "btop": "btop",
        "htop": "htop",
        "fzf": "fzf",
        "tmux": "tmux",
        "zellij": "Zellij",
        "claude": "Claude",
        "aider": "Aider",
        "copilot": "Copilot",
        "cody": "Cody",
        "goose": "Goose",
        "mentat": "Mentat",
        "ollama": "Ollama",
        "sgpt": "ShellGPT",
        "fabric": "Fabric"
    ]

    private static let categoryMap: [String: String] = [
        "vim": "editor", "nvim": "editor", "vi": "editor", "nano": "editor",
        "emacs": "editor", "helix": "editor", "hx": "editor", "micro": "editor",
        "code": "editor", "cursor": "editor",
        "git": "vcs", "lazygit": "vcs", "tig": "vcs", "gh": "vcs",
        "node": "runtime", "deno": "runtime", "bun": "runtime",
        "python": "runtime", "python3": "runtime", "ruby": "runtime", "irb": "runtime",
        "php": "runtime", "lua": "runtime", "luajit": "runtime",
        "swift": "runtime", "swiftc": "runtime", "cargo": "runtime", "rustc": "runtime",
        "go": "runtime", "java": "runtime", "kotlin": "runtime",
        "elixir": "runtime", "iex": "runtime", "erl": "runtime",
        "make": "build", "cmake": "build", "ninja": "build", "gradle": "build", "mvn": "build",
        "npm": "package", "yarn": "package", "pnpm": "package",
        "pip": "package", "pip3": "package", "brew": "package",
        "zig": "build",
        "ssh": "network", "curl": "network", "wget": "network", "ping": "network",
        "docker": "container", "docker-compose": "container", "podman": "container",
        "kubectl": "container", "k9s": "container", "helm": "container",
        "top": "monitor", "htop": "monitor", "btop": "monitor", "glances": "monitor",
        "psql": "database", "mysql": "database", "sqlite3": "database",
        "redis-cli": "database", "mongosh": "database", "mongo": "database",
        "lazydocker": "container", "tmux": "multiplexer", "screen": "multiplexer",
        "zellij": "multiplexer",
        "ranger": "filemanager", "yazi": "filemanager", "lf": "filemanager",
        "nnn": "filemanager", "mc": "filemanager",
        "claude": "ai", "aider": "ai",
        "copilot": "ai", "cody": "ai", "continue": "ai", "cursor-cli": "ai",
        "goose": "ai", "mentat": "ai", "gpt": "ai", "ollama": "ai",
        "llm": "ai", "sgpt": "ai", "tgpt": "ai", "mods": "ai", "fabric": "ai"
    ]
}
