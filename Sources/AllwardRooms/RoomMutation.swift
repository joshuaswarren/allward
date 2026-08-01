import AllwardCore
import AllwardDesign
import Foundation

/// Creating, renaming and deleting Rooms.
///
/// Rooms shipped as a fixed pair, Personal and Work, and the settings empty
/// state told people to "create a Room from the Room switcher" - which could
/// not create one. Grouping your work is the whole point of a Room, so the list
/// has to be editable.
///
/// This is deliberately a plain function over an array. Whether a Room can be
/// deleted right now also depends on which windows are open, and that check
/// belongs with the thing that knows about windows; everything here is decided
/// by the list alone, and can be checked without an application running.
public enum RoomMutation {
    /// Appends a Room with a name nobody is using yet.
    @discardableResult
    public static func add(
        to rooms: inout [Room],
        tint: TokenColor = TokenColor(hex: "#8b919b")!,
        themeName: String = "Allward Night"
    ) -> Room? {
        let used = Set(rooms.map(\.name))
        var name = "New Room"
        var suffix = 2
        while used.contains(name) {
            name = "New Room \(suffix)"
            suffix += 1
        }
        let room = Room(name: name, baseTint: tint, terminalThemeName: themeName)
        rooms.append(room)
        return room
    }

    /// Renames a Room. An empty name is a slip, not an instruction.
    @discardableResult
    public static func rename(_ id: RoomID, to name: String, in rooms: inout [Room]) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = rooms.firstIndex(where: { $0.id == id })
        else { return false }
        rooms[index].name = trimmed
        return true
    }

    /// Deletes a Room, unless it is the last one - sessions have to belong
    /// somewhere.
    @discardableResult
    public static func delete(_ id: RoomID, from rooms: inout [Room]) -> Bool {
        guard rooms.count > 1, let index = rooms.firstIndex(where: { $0.id == id })
        else { return false }
        rooms.remove(at: index)
        return true
    }
}
