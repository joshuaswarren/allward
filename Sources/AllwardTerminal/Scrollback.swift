import AllwardCore

struct Scrollback: Sendable {
    private var slots: [GridLine?]
    private var head = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int = 10_000) {
        self.capacity = max(0, capacity)
        slots = Array(repeating: nil, count: max(0, capacity))
    }

    mutating func append(_ line: GridLine) -> LineID? {
        guard capacity > 0 else { return line.id }
        var evicted: LineID?
        if count == capacity, let oldestID = slots[head]?.id {
            evicted = oldestID
            repeat {
                slots[head] = nil
                head = (head + 1) % capacity
                count -= 1
            } while count > 0 && slots[head]?.id == oldestID
        }
        slots[(head + count) % capacity] = line
        count += 1
        return evicted
    }

    mutating func removeAll() -> [LineID] {
        let ids = lines.map(\.id)
        for index in slots.indices { slots[index] = nil }
        head = 0
        count = 0
        return ids
    }

    var lines: [GridLine] {
        guard count > 0 else { return [] }
        return (0..<count).compactMap { slots[(head + $0) % capacity] }
    }

    func contains(_ id: LineID) -> Bool {
        guard count > 0 else { return false }
        return (0..<count).contains { slots[(head + $0) % capacity]?.id == id }
    }

    func line(for id: LineID) -> GridLine? {
        guard count > 0 else { return nil }
        for index in 0..<count {
            let line = slots[(head + index) % capacity]
            if line?.id == id { return line }
        }
        return nil
    }

    func lineID(forViewportRow row: Int, viewportIDs: [LineID], scrollOffset: Int) -> LineID? {
        let combined = lines.map(\.id) + viewportIDs
        let start = max(0, combined.count - viewportIDs.count - max(0, scrollOffset))
        let index = start + row
        return combined.indices.contains(index) ? combined[index] : nil
    }

    mutating func replace(with newLines: [GridLine]) -> [LineID] {
        let previousIDs = Set(lines.map(\.id))
        for index in slots.indices { slots[index] = nil }
        head = 0
        count = 0
        var start = max(0, newLines.count - capacity)
        while start > 0, start < newLines.count, newLines[start - 1].id == newLines[start].id {
            start += 1
        }
        if start < newLines.count {
            for line in newLines[start...] { _ = append(line) }
        }
        let retainedIDs = Set(lines.map(\.id))
        return Array(previousIDs.subtracting(retainedIDs))
    }
}
