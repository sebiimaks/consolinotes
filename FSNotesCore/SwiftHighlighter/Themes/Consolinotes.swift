//
//  Consolinotes.swift
//  FSNotes
//
//  Code theme matching the consolinotes (Modern TUI) palette in Images.xcassets/TUI.
//  Keep these values in sync with the TUI colour sets and MPreview.bundle/styles/consolinotes-*.min.css.
//

#if os(OSX)
struct ConsolinotesDarkTheme {
    static func make() -> HighlightStyle {
        return ConsolinotesPalette(
            text: "#c9cedc", background: "#1a1c25", comment: "#979eb7", keyword: "#bb9af7",
            string: "#9ece6a", number: "#ff9e64", title: "#7aa2f7", type: "#7dcfff",
            literal: "#73daca", tag: "#f7768e", strong: "#eef1f8"
        ).style()
    }
}

struct ConsolinotesLightTheme {
    static func make() -> HighlightStyle {
        return ConsolinotesPalette(
            text: "#2b2d36", background: "#eeece5", comment: "#555a69", keyword: "#7a47c2",
            string: "#316612", number: "#944200", title: "#2d5bd0", type: "#0b6a8a",
            literal: "#136257", tag: "#a82340", strong: "#101118"
        ).style()
    }
}

private struct ConsolinotesPalette {
    let text, background, comment, keyword, string, number, title, type, literal, tag, strong: String

    func style() -> HighlightStyle {
        var style = HighlightStyle()

        style.font = UserDefaultsManagement.codeFont
        style.foregroundColor = PlatformColor(hex: text)
        style.backgroundColor = PlatformColor(hex: background)

        func set(_ names: [String], _ hex: String, _ traits: FontTraits = []) {
            for name in names {
                style.styles[name] = .init(color: PlatformColor(hex: hex), traits: traits)
            }
        }

        set(["comment", "quote"], comment, [.italic])
        set(["keyword", "formula", "doctag"], keyword)
        set(["string", "regexp", "addition", "attribute"], string)
        set(["number", "attr", "variable", "template-variable"], number)
        set(["title", "symbol", "bullet", "link", "meta", "id", "section"], title)
        set(["type", "built_in", "class"], type)
        set(["literal"], literal)
        set(["name", "tag", "deletion", "subst"], tag)
        set(["emphasis"], text, [.italic])
        set(["strong"], strong, [.bold])

        return style
    }
}
#endif
