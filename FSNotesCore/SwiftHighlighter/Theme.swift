//
//  Theme.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 01.12.2025.
//  Copyright © 2025 Oleksandr Hlushchenko. All rights reserved.
//

enum EditorTheme: String, CaseIterable, Codable {
    case github
    case atomOne
    case solarized
    case consolinotes

    init?(themeName: String) {
        switch themeName.lowercased() {
        case "github":
            self = .github
        case "atom-one":
            self = .atomOne
        case "solarized":
            self = .solarized
        case "consolinotes":
            self = .consolinotes
        default:
            return nil
        }
    }

    func makeStyle(isDark: Bool) -> HighlightStyle {
        switch (self, isDark) {
        case (.github, false):
            return GitHubLightTheme.make()
        case (.github, true):
            return GitHubDarkTheme.make()

        case (.atomOne, false):
            return AtomOneLightTheme.make()
        case (.atomOne, true):
            return AtomOneDarkTheme.make()

        case (.solarized, false):
            return SolarizedLightTheme.make()
        case (.solarized, true):
            return SolarizedDarkTheme.make()

        case (.consolinotes, false):
            return ConsolinotesLightTheme.make()
        case (.consolinotes, true):
            return ConsolinotesDarkTheme.make()
        }
    }

    func getName() -> String {
        switch self {
        case .github:
            return "github"
        case .atomOne:
            return "atom-one"
        case .solarized:
            return "solarized"
        case .consolinotes:
            return "consolinotes"
        }
    }

    func getCssName(isDark: Bool) -> String {
        return getName() + "-" + (isDark ? "dark" : "light")
    }
}
