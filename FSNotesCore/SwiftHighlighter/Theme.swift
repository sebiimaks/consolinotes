//
//  Theme.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 01.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

/// Code block themes. Each has a highlighter style for the editor and a stylesheet in
/// MPreview.bundle/styles named `<name>-dark` / `<name>-light` for the preview.
enum EditorTheme: String, CaseIterable, Codable {
    case consolinotes
    case gruvbox
    case solarized
    case tokyoNight
    case catppuccin
    case nord
    case dracula
    case atomOne

    init?(themeName: String) {
        guard let theme = EditorTheme.allCases.first(where: { $0.getName() == themeName.lowercased() }) else {
            return nil
        }

        self = theme
    }

    func makeStyle(isDark: Bool) -> HighlightStyle {
        switch (self, isDark) {
        case (.consolinotes, false):
            return TerminalThemes.consolinotesLight.style()
        case (.consolinotes, true):
            return TerminalThemes.consolinotesDark.style()

        case (.gruvbox, false):
            return TerminalThemes.gruvboxLight.style()
        case (.gruvbox, true):
            return TerminalThemes.gruvboxDark.style()

        case (.solarized, false):
            return SolarizedLightTheme.make()
        case (.solarized, true):
            return SolarizedDarkTheme.make()

        case (.tokyoNight, false):
            return TerminalThemes.tokyoNightLight.style()
        case (.tokyoNight, true):
            return TerminalThemes.tokyoNightDark.style()

        case (.catppuccin, false):
            return TerminalThemes.catppuccinLight.style()
        case (.catppuccin, true):
            return TerminalThemes.catppuccinDark.style()

        case (.nord, _):
            return TerminalThemes.nordDark.style()

        case (.dracula, _):
            return TerminalThemes.draculaDark.style()

        case (.atomOne, false):
            return AtomOneLightTheme.make()
        case (.atomOne, true):
            return AtomOneDarkTheme.make()
        }
    }

    func getName() -> String {
        switch self {
        case .consolinotes:
            return "consolinotes"
        case .gruvbox:
            return "gruvbox"
        case .solarized:
            return "solarized"
        case .tokyoNight:
            return "tokyo-night"
        case .catppuccin:
            return "catppuccin"
        case .nord:
            return "nord"
        case .dracula:
            return "dracula"
        case .atomOne:
            return "atom-one"
        }
    }

    /// Nord and Dracula only come dark, and keep that look in light mode.
    var hasLightVariant: Bool {
        return self != .nord && self != .dracula
    }

    func getCssName(isDark: Bool) -> String {
        return getName() + "-" + (isDark || !hasLightVariant ? "dark" : "light")
    }
}
