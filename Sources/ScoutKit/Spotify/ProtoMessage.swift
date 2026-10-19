import Foundation

// A bounded protobuf editor for the exact descriptors extracted from the user's
// Spotify binary. Unknown fields are retained, so host data is not reconstructed.
public struct ProtoMessage: Equatable {
    public struct Field: Equatable {
        public var number: Int
        public var wire: Int
        public var bytes: Data
        public var integer: UInt64
    }
    public var fields: [Field] = []
    public init() {}
    public init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count <= 32_000_000 else { throw Failure.oversized }
        var index = 0
        func read() throws -> UInt64 {
            var result: UInt64 = 0
            for offset in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw Failure.truncated }
                let b = bytes[index]; index += 1
                if offset == 63 && b > 1 { throw Failure.malformed }
                result |= UInt64(b & 127) << offset
                if b < 128 { return result }
            }
            throw Failure.malformed
        }
        while index < bytes.count {
            guard fields.count < 100_000 else { throw Failure.oversized }
            let tag = try read(); let number = Int(tag >> 3), wire = Int(tag & 7)
            guard number > 0, number <= 536_870_911 else { throw Failure.malformed }
            var field = Field(number: number, wire: wire, bytes: Data(), integer: 0)
            if wire == 0 { field.integer = try read() }
            else {
                let size: Int
                switch wire {
                case 1: size = 8
                case 2:
                    let length = try read()
                    guard length <= UInt64(bytes.count - index) else { throw Failure.truncated }
                    size = Int(length)
                case 5: size = 4
                default: throw Failure.malformed
                }
                guard size <= bytes.count - index else { throw Failure.truncated }
                field.bytes = Data(bytes[index..<index + size]); index += size
            }
            fields.append(field)
        }
    }
    public enum Failure: Error { case truncated, malformed, oversized }
    public func values(_ number: Int) -> [Field] { fields.filter { $0.number == number } }
    public func data(_ number: Int) -> Data? { fields.last { $0.number == number && $0.wire == 2 }?.bytes }
    public func string(_ number: Int) -> String? { data(number).flatMap { String(data: $0, encoding: .utf8) } }
    public func uint(_ number: Int) -> UInt64? { fields.last { $0.number == number && $0.wire == 0 }?.integer }
    public func message(_ number: Int) -> ProtoMessage? { data(number).flatMap { try? ProtoMessage($0) } }
    public mutating func remove(_ number: Int) { fields.removeAll { $0.number == number } }
    public mutating func append(_ number: Int, data: Data) { fields.append(Field(number: number, wire: 2, bytes: data, integer: 0)) }
    public mutating func set(_ number: Int, data: Data) { remove(number); append(number, data: data) }
    public mutating func set(_ number: Int, string: String) { set(number, data: Data(string.utf8)) }
    public mutating func set(_ number: Int, uint: UInt64) { remove(number); fields.append(Field(number: number, wire: 0, bytes: Data(), integer: uint)) }
    public var encoded: Data {
        var data = Data()
        func write(_ value: UInt64) {
            var v = value
            while v > 127 { data.append(UInt8(v & 127) | 128); v >>= 7 }
            data.append(UInt8(v))
        }
        for field in fields {
            write(UInt64(field.number << 3 | field.wire))
            if field.wire == 0 { write(field.integer) }
            else { if field.wire == 2 { write(UInt64(field.bytes.count)) }; data.append(field.bytes) }
        }
        return data
    }
}
