import CoreMedia
import Foundation
import VideoToolbox

enum VideoToolboxProbe {
    static func run(buildReport: BuildReport) -> CapabilityReport {
        let inventory = enumerateEncoders()
        let probes = configurations.map(probe)

        return CapabilityReport(
            schemaVersion: "1.0",
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            app: AppIdentity(
                version: buildReport.appVersion,
                build: buildReport.buildNumber,
                commitSHA: buildReport.commitSHA
            ),
            device: DeviceIdentity(
                identifier: buildReport.deviceIdentifier,
                model: buildReport.deviceModel,
                systemName: buildReport.systemName,
                systemVersion: buildReport.systemVersion
            ),
            encoderEnumeration: inventory.result,
            encoders: inventory.encoders,
            configurationProbes: probes
        )
    }

    private static let configurations: [EncoderProbeConfiguration] = [
        EncoderProbeConfiguration(
            label: "H.264 1080p",
            codecType: kCMVideoCodecType_H264,
            codecFourCC: fourCC(kCMVideoCodecType_H264),
            width: 1_920,
            height: 1_080,
            requiresHardwareEncoder: true
        ),
        EncoderProbeConfiguration(
            label: "HEVC 1080p",
            codecType: kCMVideoCodecType_HEVC,
            codecFourCC: fourCC(kCMVideoCodecType_HEVC),
            width: 1_920,
            height: 1_080,
            requiresHardwareEncoder: true
        ),
        EncoderProbeConfiguration(
            label: "HEVC 4K",
            codecType: kCMVideoCodecType_HEVC,
            codecFourCC: fourCC(kCMVideoCodecType_HEVC),
            width: 3_840,
            height: 2_160,
            requiresHardwareEncoder: true
        ),
    ]

    private static func enumerateEncoders() -> (result: APICallResult, encoders: [EncoderInventoryItem]) {
        var encoderList: CFArray?
        let status = VTCopyVideoEncoderList(nil, &encoderList)
        let result = APICallResult(function: "VTCopyVideoEncoderList", status: status)

        guard status == noErr, let dictionaries = encoderList as? [NSDictionary] else {
            return (result, [])
        }

        let encoders = dictionaries.enumerated().map { index, dictionary in
            let codecType = (dictionary.object(forKey: kVTVideoEncoderList_CodecType) as? NSNumber)?.uint32Value ?? 0
            let encoderID = dictionary.object(forKey: kVTVideoEncoderList_EncoderID) as? String ?? "unknown-\(index)"
            let displayName = dictionary.object(forKey: kVTVideoEncoderList_DisplayName) as? String ?? encoderID
            let encoderName = dictionary.object(forKey: kVTVideoEncoderList_EncoderName) as? String

            return EncoderInventoryItem(
                index: index,
                encoderID: encoderID,
                displayName: displayName,
                encoderName: encoderName,
                codecType: codecType,
                codecFourCC: fourCC(codecType),
                rawDictionary: JSONValue(foundationValue: dictionary)
            )
        }

        return (result, encoders)
    }

    private static func probe(_ configuration: EncoderProbeConfiguration) -> EncoderConfigurationProbe {
        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ] as CFDictionary

        var selectedEncoderID: CFString?
        var preflightProperties: CFDictionary?
        let preflightStatus = VTCopySupportedPropertyDictionaryForEncoder(
            width: configuration.width,
            height: configuration.height,
            codecType: configuration.codecType,
            encoderSpecification: encoderSpecification,
            encoderIDOut: &selectedEncoderID,
            supportedPropertiesOut: &preflightProperties
        )
        let preflight = APICallResult(
            function: "VTCopySupportedPropertyDictionaryForEncoder",
            status: preflightStatus
        )

        var compressionSession: VTCompressionSession?
        let sessionStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: configuration.width,
            height: configuration.height,
            codecType: configuration.codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &compressionSession
        )
        let sessionCreation = APICallResult(function: "VTCompressionSessionCreate", status: sessionStatus)

        var evidence: [EvidenceLevel] = []
        if preflight.succeeded {
            evidence.append(.preflight)
        }

        guard sessionStatus == noErr, let compressionSession else {
            return EncoderConfigurationProbe(
                configuration: configuration,
                preflight: preflight,
                selectedEncoderID: selectedEncoderID.map { $0 as String },
                preflightSupportedProperties: jsonValue(preflightProperties),
                sessionCreation: sessionCreation,
                sessionPropertyQuery: nil,
                sessionSupportedProperties: nil,
                hardwarePropertyQuery: nil,
                usesHardwareEncoder: nil,
                evidence: evidence
            )
        }
        defer {
            VTCompressionSessionInvalidate(compressionSession)
        }

        evidence.append(.sessionCreated)

        var sessionProperties: CFDictionary?
        let sessionPropertyStatus = VTSessionCopySupportedPropertyDictionary(
            compressionSession,
            supportedPropertyDictionaryOut: &sessionProperties
        )
        let sessionPropertyQuery = APICallResult(
            function: "VTSessionCopySupportedPropertyDictionary",
            status: sessionPropertyStatus
        )
        if sessionPropertyQuery.succeeded {
            evidence.append(.sessionPropertiesRead)
        }

        var hardwareProperty: CFTypeRef?
        let hardwarePropertyStatus = VTSessionCopyProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: nil,
            valueOut: &hardwareProperty
        )
        let hardwarePropertyQuery = APICallResult(
            function: "VTSessionCopyProperty(UsingHardwareAcceleratedVideoEncoder)",
            status: hardwarePropertyStatus
        )
        let usesHardwareEncoder = (hardwareProperty as? NSNumber)?.boolValue
        if hardwarePropertyQuery.succeeded, usesHardwareEncoder == true {
            evidence.append(.hardwareRuntimeProperty)
        }

        return EncoderConfigurationProbe(
            configuration: configuration,
            preflight: preflight,
            selectedEncoderID: selectedEncoderID.map { $0 as String },
            preflightSupportedProperties: jsonValue(preflightProperties),
            sessionCreation: sessionCreation,
            sessionPropertyQuery: sessionPropertyQuery,
            sessionSupportedProperties: jsonValue(sessionProperties),
            hardwarePropertyQuery: hardwarePropertyQuery,
            usesHardwareEncoder: usesHardwareEncoder,
            evidence: evidence
        )
    }

    private static func jsonValue(_ dictionary: CFDictionary?) -> JSONValue? {
        dictionary.map { JSONValue(foundationValue: $0 as NSDictionary) }
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", value)
    }
}
