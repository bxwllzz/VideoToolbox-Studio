import Foundation

struct CapabilityReport: Encodable, Sendable {
    let schemaVersion: String
    let generatedAt: String
    let app: AppIdentity
    let device: DeviceIdentity
    let encoderEnumeration: APICallResult
    let encoders: [EncoderInventoryItem]
    let configurationProbes: [EncoderConfigurationProbe]

    var successfulHardwareSessionCount: Int {
        configurationProbes.filter { $0.usesHardwareEncoder == true }.count
    }
}

struct AppIdentity: Encodable, Sendable {
    let version: String
    let build: String
    let commitSHA: String
}

struct DeviceIdentity: Encodable, Sendable {
    let identifier: String
    let model: String
    let systemName: String
    let systemVersion: String
}

struct APICallResult: Encodable, Sendable {
    let function: String
    let status: Int32
    let message: String

    var succeeded: Bool {
        status == 0
    }

    init(function: String, status: Int32) {
        self.function = function
        self.status = status
        message = status == 0
            ? "成功"
            : NSError(domain: NSOSStatusErrorDomain, code: Int(status)).localizedDescription
    }
}

struct EncoderInventoryItem: Encodable, Identifiable, Sendable {
    let index: Int
    let encoderID: String
    let displayName: String
    let encoderName: String?
    let codecType: UInt32
    let codecFourCC: String
    let rawDictionary: JSONValue

    var id: String {
        "\(index)-\(encoderID)"
    }
}

struct EncoderProbeConfiguration: Encodable, Sendable {
    let label: String
    let codecType: UInt32
    let codecFourCC: String
    let width: Int32
    let height: Int32
    let requiresHardwareEncoder: Bool
}

enum EvidenceLevel: String, Encodable, Sendable {
    case preflight = "E1"
    case sessionCreated = "E2"
    case sessionPropertiesRead = "E3"
    case bitstreamProduced = "E4"
    case hardwareRuntimeProperty = "E5"
    case sustainedThroughput = "E6"
}

struct EncoderConfigurationProbe: Encodable, Identifiable, Sendable {
    let configuration: EncoderProbeConfiguration
    let preflight: APICallResult
    let selectedEncoderID: String?
    let preflightSupportedProperties: JSONValue?
    let sessionCreation: APICallResult
    let sessionPropertyQuery: APICallResult?
    let sessionSupportedProperties: JSONValue?
    let hardwarePropertyQuery: APICallResult?
    let usesHardwareEncoder: Bool?
    let evidence: [EvidenceLevel]

    var id: String {
        configuration.label
    }

    var evidenceSummary: String {
        evidence.map(\.rawValue).joined(separator: " · ")
    }
}
