import Foundation

enum SMP {
    static let groupImage: UInt16 = 1
    static let idImageUpload: UInt8 = 1
    static let opWrite: UInt8 = 2
    static let opWriteResponse: UInt8 = 3
    static let minimumPayloadSize = 32

    struct PendingRequest {
        let sequence: UInt8
        let offset: Int
        let chunkSize: Int
        let packet: Data
    }

    static func imageUploadRequest(sequence: UInt8, slot: Int, offset: Int, data: Data, totalSize: Int) -> Data {
        var fields: [(String, Data)] = [
            ("off", cborUInt(offset)),
            ("data", cborBytes(data))
        ]

        if offset == 0 {
            fields.insert(("image", cborUInt(slot + 1)), at: 0)
            fields.insert(("len", cborUInt(totalSize)), at: 1)
        }

        let payload = cborMap(fields)
        var packet = Data()
        packet.append(opWrite)
        packet.append(0)
        packet.append(UInt8((payload.count >> 8) & 0xff))
        packet.append(UInt8(payload.count & 0xff))
        packet.append(UInt8((groupImage >> 8) & 0xff))
        packet.append(UInt8(groupImage & 0xff))
        packet.append(sequence)
        packet.append(idImageUpload)
        packet.append(payload)
        return packet
    }

    static func responseSequenceAndOffset(_ packet: Data) throws -> (sequence: UInt8, offset: Int) {
        guard packet.count >= 8 else { throw SMPError.invalidResponse("header too short") }
        let op = packet[0]
        let length = (Int(packet[2]) << 8) | Int(packet[3])
        let group = (UInt16(packet[4]) << 8) | UInt16(packet[5])
        let sequence = packet[6]
        let command = packet[7]

        guard op == opWriteResponse, group == groupImage, command == idImageUpload else {
            throw SMPError.invalidResponse("unexpected response header")
        }
        guard packet.count >= 8 + length else {
            throw SMPError.invalidResponse("payload too short")
        }
        if length == 0 {
            return (sequence, -1)
        }

        let payload = packet.subdata(in: 8..<(8 + length))
        let decoded = try CBORDecoder(payload).decodeValue()
        guard let map = decoded as? [String: Any] else {
            throw SMPError.invalidResponse("payload is not a CBOR map")
        }
        if let rc = map["rc"] as? Int, rc != 0 {
            throw SMPError.remoteError(rc)
        }
        if let err = map["err"] as? [String: Any], let rc = err["rc"] as? Int {
            throw SMPError.remoteError(rc)
        }

        return (sequence, map["off"] as? Int ?? -1)
    }

    static func maxPayloadSize(forMTU mtu: Int) -> Int {
        let maxWriteValueSize = mtu - 3
        var payloadSize = 0
        while imageUploadRequest(sequence: 0, slot: 255, offset: 0, data: Data(count: payloadSize + 1), totalSize: Int(UInt32.max)).count <= maxWriteValueSize {
            payloadSize += 1
        }
        return payloadSize
    }

    static func cborUInt(_ value: Int) -> Data {
        if value < 24 { return Data([UInt8(value)]) }
        if value <= 0xff { return Data([0x18, UInt8(value)]) }
        if value <= 0xffff { return Data([0x19, UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]) }
        return Data([0x1a, UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)])
    }

    static func cborText(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        return Data([UInt8(0x60) + UInt8(bytes.count)]) + bytes
    }

    static func cborBytes(_ value: Data) -> Data {
        if value.count < 24 {
            return Data([UInt8(0x40) + UInt8(value.count)]) + value
        }
        if value.count <= 0xff {
            return Data([0x58, UInt8(value.count)]) + value
        }
        return Data([0x59, UInt8((value.count >> 8) & 0xff), UInt8(value.count & 0xff)]) + value
    }

    static func cborMap(_ fields: [(String, Data)]) -> Data {
        var result = Data([UInt8(0xa0) + UInt8(fields.count)])
        for field in fields {
            result.append(cborText(field.0))
            result.append(field.1)
        }
        return result
    }
}

enum SMPError: Error, LocalizedError {
    case invalidResponse(String)
    case remoteError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let reason):
            return "Invalid SMP response: \(reason)"
        case .remoteError(let rc):
            return "SMP upload failed with rc=\(rc)"
        }
    }
}

final class CBORDecoder {
    private let data: Data
    private var index = 0

    init(_ data: Data) {
        self.data = data
    }

    func decodeValue() throws -> Any {
        let head = try readByte()
        let major = head >> 5
        let value = head & 0x1f

        switch major {
        case 0:
            return try readLength(value)
        case 1:
            return -1 - (try readLength(value))
        case 2:
            let length = try readLength(value)
            return try readData(length)
        case 3:
            let length = try readLength(value)
            return String(decoding: try readData(length), as: UTF8.self)
        case 4:
            if value == 31 {
                var values: [Any] = []
                while !isAtBreak() {
                    values.append(try decodeValue())
                }
                try readBreak()
                return values
            }

            let length = try readLength(value)
            return try (0..<length).map { _ in try decodeValue() }
        case 5:
            var map: [String: Any] = [:]
            if value == 31 {
                while !isAtBreak() {
                    guard let key = try decodeValue() as? String else {
                        throw SMPError.invalidResponse("CBOR map key is not text")
                    }
                    map[key] = try decodeValue()
                }
                try readBreak()
                return map
            }

            let length = try readLength(value)
            for _ in 0..<length {
                guard let key = try decodeValue() as? String else {
                    throw SMPError.invalidResponse("CBOR map key is not text")
                }
                map[key] = try decodeValue()
            }
            return map
        case 7 where value == 20:
            return false
        case 7 where value == 21:
            return true
        case 7 where value == 22 || value == 23:
            return NSNull()
        default:
            throw SMPError.invalidResponse("unsupported CBOR type")
        }
    }

    private func readByte() throws -> UInt8 {
        guard index < data.count else { throw SMPError.invalidResponse("unexpected end of CBOR") }
        defer { index += 1 }
        return data[index]
    }

    private func readLength(_ value: UInt8) throws -> Int {
        if value < 24 { return Int(value) }
        if value == 24 { return Int(try readByte()) }
        if value == 25 {
            let high = Int(try readByte())
            let low = Int(try readByte())
            return (high << 8) | low
        }
        if value == 26 {
            var result = 0
            for _ in 0..<4 {
                result = (result << 8) | Int(try readByte())
            }
            return result
        }
        throw SMPError.invalidResponse("unsupported CBOR integer width")
    }

    private func isAtBreak() -> Bool {
        index < data.count && data[index] == 0xff
    }

    private func readBreak() throws {
        guard isAtBreak() else {
            throw SMPError.invalidResponse("expected CBOR break")
        }
        index += 1
    }

    private func readData(_ length: Int) throws -> Data {
        guard index + length <= data.count else {
            throw SMPError.invalidResponse("CBOR data length exceeds payload")
        }
        defer { index += length }
        return data.subdata(in: index..<(index + length))
    }
}
