@testable import GhosttyTerminal
import Testing

struct TerminalInputTextTests {
    @Test
    func `normalizes software keyboard return to carriage return`() {
        #expect(TerminalInputText.normalizingSoftwareReturn("\n") == "\r")
        #expect(TerminalInputText.normalizingSoftwareReturn("\r\n") == "\r")
        #expect(TerminalInputText.normalizingSoftwareReturn("\r") == "\r")
        #expect(TerminalInputText.normalizingSoftwareReturn("text") == "text")
    }

    @Test
    func `hardware tab stays a physical key for shift tab`() {
        #expect(TerminalInputText.hardwareKeyText(
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            optionActsAsAlt: false,
            usage: 0x2B
        ) == nil)
    }

    @Test
    func `option as alt uses modifier independent hardware text`() {
        #expect(TerminalInputText.hardwareKeyText(
            characters: "å",
            charactersIgnoringModifiers: "a",
            optionActsAsAlt: true,
            usage: 0x04
        ) == "a")
        #expect(TerminalInputText.hardwareKeyText(
            characters: "å",
            charactersIgnoringModifiers: "a",
            optionActsAsAlt: false,
            usage: 0x04
        ) == "å")
    }

    @Test
    func `filters apple private use function keys from text path`() {
        #expect(TerminalInputText.filteredFunctionKeyText("\u{F702}") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("\u{F703}") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("UIKeyInputLeftArrow") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("UIKeyInputUpArrow") == nil)
        #expect(TerminalInputText.filteredFunctionKeyText("a") == "a")
        #expect(TerminalInputText.filteredFunctionKeyText("你好") == "你好")
    }

    @Test
    func `recognizes private use function key scalars`() {
        #expect(TerminalInputText.isPrivateUseFunctionKey("\u{F702}"))
        #expect(TerminalInputText.isPrivateUseFunctionKey("\u{F703}"))
        #expect(!TerminalInputText.isPrivateUseFunctionKey("a"))
        #expect(!TerminalInputText.isPrivateUseFunctionKey("你"))
    }

    @Test
    func `recognizes UI kit named function keys`() {
        #expect(TerminalInputText.isUIKitNamedFunctionKey("UIKeyInputLeftArrow"))
        #expect(TerminalInputText.isUIKitNamedFunctionKey("UIKeyInputDownArrow"))
        #expect(!TerminalInputText.isUIKitNamedFunctionKey("a"))
        #expect(!TerminalInputText.isUIKitNamedFunctionKey("你好"))
    }

    @Test
    func `counts paste lines for diagnostics only`() {
        #expect(TerminalInputText.lineCount(in: "") == 0)
        #expect(TerminalInputText.lineCount(in: "echo ok") == 0)
        #expect(TerminalInputText.lineCount(in: "line 1\nline 2\nline 3") == 2)
    }
}
