public struct AttributeTable: Sendable {
    private var values: [CellAttributes] = [.default]
    private var indices: [CellAttributes: UInt32] = [.default: 0]

    public init() {}

    public mutating func intern(_ attributes: CellAttributes) -> UInt32 {
        if let existing = indices[attributes] { return existing }
        let index = UInt32(values.count)
        values.append(attributes)
        indices[attributes] = index
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
