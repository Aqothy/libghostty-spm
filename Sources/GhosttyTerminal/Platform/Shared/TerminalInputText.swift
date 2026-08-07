//
//  TerminalInputText.swift
//  libghostty-spm
//
//  Reference:
//  - ghostty-org/ghostty
//  - macos/Sources/Ghostty/NSEvent+Extension.swift
//  Keep the AppKit text filtering here aligned with Ghostty's native
//  `ghosttyCharacters` behavior so future upstream syncs stay mechanical.

import Foundation

enum TerminalInputText {
    /// A terminal's Enter key is carriage return; line feed remains Ctrl-J.
    /// UIKit software keyboards may commit Return as LF or CRLF.
    static func normalizingSoftwareReturn(_ text: String) -> String {
        switch text {
        case "\n", "\r\n": "\r"
        default: text
        }
    }

    /// Text associated with a UIKit hardware-key event. Tab must stay a
    /// physical key so Shift-Tab can be encoded as Backtab. When Ghostty's
    /// Option-as-Alt policy removes Option from text translation, use UIKit's
    /// modifier-independent text while retaining Alt on the key event.
    static func hardwareKeyText(
        characters: String,
        charactersIgnoringModifiers: String,
        optionActsAsAlt: Bool,
        usage: UInt16
    ) -> String? {
        guard usage != 0x2B else { return nil }
        return filteredFunctionKeyText(
            optionActsAsAlt ? charactersIgnoringModifiers : characters
        )
    }

    /// Base-layout codepoint for a synthetic printable key event. Ghostty
    /// needs this in addition to `text` to apply enhanced keyboard protocols
    /// instead of treating a modified key as plain committed text.
    static func unshiftedCodepoint(forModifiedText text: String) -> UInt32? {
        guard text.count == 1, let character = text.first else { return nil }

        let unshifted: Character
        switch character {
        case "A" ... "Z":
            guard let lowercase = character.lowercased().first else { return nil }
            unshifted = lowercase
        case "!": unshifted = "1"
        case "@": unshifted = "2"
        case "#": unshifted = "3"
        case "$": unshifted = "4"
        case "%": unshifted = "5"
        case "^": unshifted = "6"
        case "&": unshifted = "7"
        case "*": unshifted = "8"
        case "(": unshifted = "9"
        case ")": unshifted = "0"
        case "~": unshifted = "`"
        case "_": unshifted = "-"
        case "+": unshifted = "="
        case "{": unshifted = "["
        case "}": unshifted = "]"
        case "|": unshifted = "\\"
        case ":": unshifted = ";"
        case "\"": unshifted = "'"
        case "<": unshifted = ","
        case ">": unshifted = "."
        case "?": unshifted = "/"
        default: unshifted = character
        }
        return unshifted.unicodeScalars.first?.value
    }

    static func filteredFunctionKeyText(_ text: String?) -> String? {
        guard let text else { return nil }
        if isUIKitNamedFunctionKey(text) {
            return nil
        }
        guard text.count == 1, let scalar = text.unicodeScalars.first else {
            return text
        }

        if isPrivateUseFunctionKey(scalar) {
            return nil
        }

        return text
    }

    static func lineCount(in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    static func isPrivateUseFunctionKey(_ scalar: UnicodeScalar) -> Bool {
        scalar.value >= 0xF700 && scalar.value <= 0xF8FF
    }

    static func isUIKitNamedFunctionKey(_ text: String) -> Bool {
        text.hasPrefix("UIKeyInput")
    }
}
