public struct GraphemeTable: Sendable {
    private var values: [String] = [" "]
    private var indices: [String: UInt32] = [" ": 0]

    public init() {}

    /// Indices for the printable ASCII range, so the common case never hashes
    /// a String. Interning by String key cost more than every other part of
    /// printing a character put together.
    private var ascii = [UInt32](repeating: .max, count: 128)

    public mutating func internASCII(_ byte: UInt8) -> UInt32 {
        let slot = Int(byte)
        let cached = ascii[slot]
        if cached != .max { return cached }
        let index = intern(String(UnicodeScalar(byte)))
        ascii[slot] = index
        return index
    }

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
