import AllwardConfig
import AllwardDesign
import AllwardRenderer
import AllwardRooms

/// The Room owns the terminal theme; the renderer only paints it.
///
/// DESIGN-LANGUAGE §20.3 is explicit that the grid follows its selected theme
/// while Allward-owned chrome follows the resolved UI appearance. Deriving the
/// grid from the system appearance would make a configured dark Room turn white
/// when macOS switches to light, which is neither what the user asked for nor
/// what any other terminal does.
enum TerminalThemeBridge {
    static func rendererTheme(
        named name: String, terminal: TerminalConfiguration = TerminalConfiguration()
    ) -> AllwardRenderer.TerminalTheme {
        convert(ThemeCatalog.theme(named: name) ?? ThemeCatalog.darkDefault, terminal: terminal)
    }

    static func convert(
        _ theme: AllwardRooms.TerminalTheme,
        terminal: TerminalConfiguration = TerminalConfiguration()
    ) -> AllwardRenderer.TerminalTheme {
        AllwardRenderer.TerminalTheme(
            ansiColors: theme.ansi + theme.brights,
            defaultForeground: theme.foreground,
            defaultBackground: theme.background,
            cursor: theme.cursor ?? theme.foreground,
            selectionBackground: theme.selection ?? theme.brights[4],
            selectionForeground: theme.background,
            boldIsBright: terminal.boldIsBright,
            minimumContrast: terminal.minimumContrast
        )
    }
}
