public struct UTF8Decoder: Sendable {
    private var value: UInt32 = 0
    private var minimum: UInt32 = 0
    private var remaining = 0

    public init() {}

    public var hasPendingSequence: Bool { remaining != 0 }

    public mutating func decode(_ bytes: ArraySlice<UInt8>) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            consume(byte) { scalars.append($0) }
        }
        return scalars
    }

    public mutating func consume(_ byte: UInt8, emit: (Unicode.Scalar) -> Void) {
        if remaining == 0 {
            start(byte, emit: emit)
            return
        }
        guard byte & 0xC0 == 0x80 else {
            reset()
            emit("\u{FFFD}")
            start(byte, emit: emit)
            return
        }
        value = (value << 6) | UInt32(byte & 0x3F)
        remaining -= 1
        guard remaining == 0 else { return }
        let scalarValue = value
        let isValid = scalarValue >= minimum
            && scalarValue <= 0x10FFFF
            && !(0xD800...0xDFFF).contains(scalarValue)
        reset()
        emit(isValid ? Unicode.Scalar(scalarValue)! : "\u{FFFD}")
    }

    public mutating func finish(emit: (Unicode.Scalar) -> Void) {
        guard remaining != 0 else { return }
        reset()
        emit("\u{FFFD}")
    }

    private mutating func start(_ byte: UInt8, emit: (Unicode.Scalar) -> Void) {
        switch byte {
        case 0x00...0x7F:
            emit(Unicode.Scalar(byte))
        case 0xC2...0xDF:
            value = UInt32(byte & 0x1F)
            minimum = 0x80
            remaining = 1
        case 0xE0...0xEF:
            value = UInt32(byte & 0x0F)
            minimum = 0x800
            remaining = 2
        case 0xF0...0xF4:
            value = UInt32(byte & 0x07)
            minimum = 0x10000
            remaining = 3
        default:
            emit("\u{FFFD}")
        }
    }

    private mutating func reset() {
        value = 0
        minimum = 0
        remaining = 0
    }
}
