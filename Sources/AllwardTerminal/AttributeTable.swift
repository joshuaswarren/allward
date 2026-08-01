public struct AttributeTable: Sendable {
    private var values: [CellAttributes] = [.default]
    private var indices: [CellAttributes: UInt32] = [.default: 0]

    public init() {}

    /// Attributes change far less often than characters are printed, so the
    /// last answer is almost always the right one and costs a comparison
    /// instead of a hash and a dictionary probe.
    private var lastInterned: (attributes: CellAttributes, index: UInt32)?

    public mutating func intern(_ attributes: CellAttributes) -> UInt32 {
        if let lastInterned, lastInterned.attributes == attributes { return lastInterned.index }
        if let existing = indices[attributes] {
            lastInterned = (attributes, existing)
            return existing
        }
        let index = UInt32(values.count)
        values.append(attributes)
        indices[attributes] = index
        lastInterned = (attributes, index)
        return index
    }

    public subscript(index: UInt32) -> CellAttributes {
        values.indices.contains(Int(index)) ? values[Int(index)] : .default
    }

    public mutating func reset() {
        values = [.default]
        indices = [.default: 0]
    }
}
