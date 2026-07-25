import Foundation

struct SustainedEncodingReport: Encodable, Sendable {
    let schemaVersion: String
    let generatedAt: String
    let app: AppIdentity
    let device: DeviceIdentity
    let durationSeconds: Double
    let targetFramesPerSecond: Double
    let thermalStateBefore: String
    let thermalStateAfter: String
    let cancelled: Bool
    let configurations: [SustainedEncodingResult]

    var passedConfigurationCount: Int {
        configurations.filter(\.meetsAcceptanceTarget).count
    }
}

struct SustainedEncodingConfiguration: Encodable, Sendable {
    let label: String
    let codecType: UInt32
    let codecFourCC: String
    let width: Int32
    let height: Int32
    let framesPerSecond: Int32
    let durationSeconds: Int32
    let averageBitRate: Int
    let requiredEvidence: EvidenceLevel

    var requestedFrameCount: Int {
        Int(framesPerSecond * durationSeconds)
    }
}

struct PropertyWriteResult: Encodable, Sendable {
    let key: String
    let requestedValue: JSONValue
    let status: APICallResult
}

struct EncodedFormatSummary: Encodable, Sendable {
    let mediaSubType: UInt32
    let mediaSubTypeFourCC: String
    let width: Int32
    let height: Int32
    let extensions: JSONValue?
}

struct SustainedEncodingMetrics: Encodable, Sendable {
    let requestedFrames: Int
    let submittedFrames: Int
    let callbackFrames: Int
    let outputSampleBuffers: Int
    let failedFrames: Int
    let droppedFrames: Int
    let keyFrames: Int
    let reorderedFrames: Int
    let totalEncodedBytes: Int
    let wallClockSeconds: Double
    let throughputFramesPerSecond: Double
    let firstCallbackLatencyMilliseconds: Double?
    let meanCallbackLatencyMilliseconds: Double?
    let p95CallbackLatencyMilliseconds: Double?
    let maximumInFlightFrames: Int
    let measuredBitRate: Double
}

struct SustainedEncodingResult: Encodable, Identifiable, Sendable {
    let configuration: SustainedEncodingConfiguration
    let sessionCreation: APICallResult
    let propertyWrites: [PropertyWriteResult]
    let prepare: APICallResult?
    let pixelBufferPoolAvailable: Bool
    let completeFrames: APICallResult?
    let hardwarePropertyQuery: APICallResult?
    let usesHardwareEncoder: Bool?
    let metrics: SustainedEncodingMetrics
    let outputFormat: EncodedFormatSummary?
    let callbackStatuses: [APICallResult]
    let evidence: [EvidenceLevel]
    let cancelled: Bool

    var id: String {
        configuration.label
    }

    var evidenceSummary: String {
        evidence.map(\.rawValue).joined(separator: " · ")
    }

    var meetsAcceptanceTarget: Bool {
        evidence.contains(configuration.requiredEvidence)
    }
}
