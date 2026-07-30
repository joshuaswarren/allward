public struct GraphemeTable: Sendable {
    private var values: [String] = [" "]
    private var indices: [String: UInt32] = [" ": 0]

    public init() {}

    public mutating func intern(_ grapheme: String) -> UInt32 {
        if let existing = indices[grapheme] { return existing }
        let index = UInt32(values.count)
        values.append(grapheme)
        indices[grapheme] = index
        return index
    }

    public subscript(index: UInt32) -> String {
        values.indices.contains(Int(index)) ? values[Int(index)] : " "
    }


    public mutating func reset() {
        values = [" "]
        indices = [" ": 0]
    }
}
