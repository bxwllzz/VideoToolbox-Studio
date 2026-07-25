import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

final class EncodingCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

enum SustainedEncodingProbe {
    static let configurations: [SustainedEncodingConfiguration] = [
        SustainedEncodingConfiguration(
            label: "H.264 1080p30",
            codecType: kCMVideoCodecType_H264,
            codecFourCC: fourCC(kCMVideoCodecType_H264),
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            durationSeconds: 2,
            averageBitRate: 8_000_000,
            requiredEvidence: .sustainedThroughput
        ),
        SustainedEncodingConfiguration(
            label: "HEVC 1080p30",
            codecType: kCMVideoCodecType_HEVC,
            codecFourCC: fourCC(kCMVideoCodecType_HEVC),
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            durationSeconds: 2,
            averageBitRate: 6_000_000,
            requiredEvidence: .sustainedThroughput
        ),
        SustainedEncodingConfiguration(
            label: "HEVC 4K30",
            codecType: kCMVideoCodecType_HEVC,
            codecFourCC: fourCC(kCMVideoCodecType_HEVC),
            width: 3_840,
            height: 2_160,
            framesPerSecond: 30,
            durationSeconds: 2,
            averageBitRate: 24_000_000,
            requiredEvidence: .hardwareRuntimeProperty
        ),
    ]

    static func run(
        buildReport: BuildReport,
        cancellationToken: EncodingCancellationToken
    ) -> SustainedEncodingReport {
        let thermalStateBefore = thermalStateDescription(ProcessInfo.processInfo.thermalState)
        var results: [SustainedEncodingResult] = []

        for configuration in configurations {
            guard !cancellationToken.isCancelled else {
                break
            }
            results.append(run(configuration, cancellationToken: cancellationToken))
        }

        return SustainedEncodingReport(
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
            durationSeconds: 2,
            targetFramesPerSecond: 30,
            thermalStateBefore: thermalStateBefore,
            thermalStateAfter: thermalStateDescription(ProcessInfo.processInfo.thermalState),
            cancelled: cancellationToken.isCancelled,
            configurations: results
        )
    }

    static func percentile95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }

    private static func run(
        _ configuration: SustainedEncodingConfiguration,
        cancellationToken: EncodingCancellationToken
    ) -> SustainedEncodingResult {
        let context = EncodingCallbackContext()
        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ] as CFDictionary
        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary,
        ] as CFDictionary

        var session: VTCompressionSession?
        let sessionStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: configuration.width,
            height: configuration.height,
            codecType: configuration.codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(context).toOpaque(),
            compressionSessionOut: &session
        )
        let sessionCreation = APICallResult(
            function: "VTCompressionSessionCreate",
            status: sessionStatus
        )

        guard sessionStatus == noErr, let session else {
            return failedResult(
                configuration: configuration,
                sessionCreation: sessionCreation,
                cancelled: cancellationToken.isCancelled
            )
        }
        defer {
            VTCompressionSessionInvalidate(session)
        }

        let propertyWrites = configure(session, configuration: configuration)
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(session)
        let prepare = APICallResult(
            function: "VTCompressionSessionPrepareToEncodeFrames",
            status: prepareStatus
        )

        guard prepareStatus == noErr, let pixelBufferPool = VTCompressionSessionGetPixelBufferPool(session) else {
            return result(
                configuration: configuration,
                sessionCreation: sessionCreation,
                propertyWrites: propertyWrites,
                prepare: prepare,
                pixelBufferPoolAvailable: false,
                completeFrames: nil,
                session: session,
                context: context,
                startTime: nil,
                submittedFrames: 0,
                maximumInFlightFrames: 0,
                cancelled: cancellationToken.isCancelled
            )
        }

        let startTime = ProcessInfo.processInfo.systemUptime
        var submittedFrames = 0
        var maximumInFlightFrames = 0

        for frameIndex in 0..<configuration.requestedFrameCount {
            guard !cancellationToken.isCancelled else {
                break
            }

            var pixelBuffer: CVPixelBuffer?
            let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pixelBufferPool,
                &pixelBuffer
            )
            guard allocationStatus == kCVReturnSuccess, let pixelBuffer else {
                context.recordSubmissionFailure(
                    status: allocationStatus,
                    function: "CVPixelBufferPoolCreatePixelBuffer"
                )
                break
            }

            fill(pixelBuffer, frameIndex: frameIndex)
            let submission = FrameSubmission(
                index: frameIndex,
                submittedAt: ProcessInfo.processInfo.systemUptime
            )
            context.retain(submission)

            var infoFlags = VTEncodeInfoFlags()
            let presentationTimeStamp = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: configuration.framesPerSecond
            )
            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: CMTime(value: 1, timescale: configuration.framesPerSecond),
                frameProperties: nil,
                sourceFrameRefcon: Unmanaged.passUnretained(submission).toOpaque(),
                infoFlagsOut: &infoFlags
            )

            if encodeStatus == noErr {
                submittedFrames += 1
                let inFlight = submittedFrames - context.callbackFrameCount
                maximumInFlightFrames = max(maximumInFlightFrames, inFlight)
            } else {
                context.recordSubmissionFailure(
                    status: encodeStatus,
                    function: "VTCompressionSessionEncodeFrame[\(frameIndex)]"
                )
                break
            }
        }

        let completeStatus = VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )
        let completeFrames = APICallResult(
            function: "VTCompressionSessionCompleteFrames",
            status: completeStatus
        )

        return result(
            configuration: configuration,
            sessionCreation: sessionCreation,
            propertyWrites: propertyWrites,
            prepare: prepare,
            pixelBufferPoolAvailable: true,
            completeFrames: completeFrames,
            session: session,
            context: context,
            startTime: startTime,
            submittedFrames: submittedFrames,
            maximumInFlightFrames: maximumInFlightFrames,
            cancelled: cancellationToken.isCancelled
        )
    }

    private static func configure(
        _ session: VTCompressionSession,
        configuration: SustainedEncodingConfiguration
    ) -> [PropertyWriteResult] {
        [
            setProperty(
                session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                name: "ExpectedFrameRate",
                value: NSNumber(value: configuration.framesPerSecond)
            ),
            setProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                name: "AverageBitRate",
                value: NSNumber(value: configuration.averageBitRate)
            ),
            setProperty(
                session,
                key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                name: "MaxKeyFrameInterval",
                value: NSNumber(value: configuration.framesPerSecond)
            ),
            setProperty(
                session,
                key: kVTCompressionPropertyKey_AllowFrameReordering,
                name: "AllowFrameReordering",
                value: kCFBooleanFalse
            ),
            setProperty(
                session,
                key: kVTCompressionPropertyKey_RealTime,
                name: "RealTime",
                value: kCFBooleanFalse
            ),
            setProperty(
                session,
                key: kVTCompressionPropertyKey_SourceFrameCount,
                name: "SourceFrameCount",
                value: NSNumber(value: configuration.requestedFrameCount)
            ),
        ]
    }

    private static func setProperty(
        _ session: VTCompressionSession,
        key: CFString,
        name: String,
        value: CFTypeRef
    ) -> PropertyWriteResult {
        let status = VTSessionSetProperty(session, key: key, value: value)
        return PropertyWriteResult(
            key: name,
            requestedValue: JSONValue(foundationValue: value),
            status: APICallResult(function: "VTSessionSetProperty(\(name))", status: status)
        )
    }

    private static func result(
        configuration: SustainedEncodingConfiguration,
        sessionCreation: APICallResult,
        propertyWrites: [PropertyWriteResult],
        prepare: APICallResult?,
        pixelBufferPoolAvailable: Bool,
        completeFrames: APICallResult?,
        session: VTCompressionSession,
        context: EncodingCallbackContext,
        startTime: TimeInterval?,
        submittedFrames: Int,
        maximumInFlightFrames: Int,
        cancelled: Bool
    ) -> SustainedEncodingResult {
        var hardwareProperty: CFTypeRef?
        let hardwareStatus = VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: nil,
            valueOut: &hardwareProperty
        )
        let usesHardwareEncoder = (hardwareProperty as? NSNumber)?.boolValue
        let snapshot = context.snapshot()
        let wallClockSeconds = startTime.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        } ?? 0
        let outputFrames = snapshot.outputSampleBuffers
        let throughput = wallClockSeconds > 0
            ? Double(outputFrames) / wallClockSeconds
            : 0
        let measuredBitRate = wallClockSeconds > 0
            ? Double(snapshot.totalEncodedBytes * 8) / wallClockSeconds
            : 0
        let meanLatency = snapshot.latenciesMilliseconds.isEmpty
            ? nil
            : snapshot.latenciesMilliseconds.reduce(0, +)
                / Double(snapshot.latenciesMilliseconds.count)
        let callbackStatuses = snapshot.callbackStatuses + snapshot.submissionFailures
        let failedFrames = callbackStatuses.filter { !$0.succeeded }.count

        let metrics = SustainedEncodingMetrics(
            requestedFrames: configuration.requestedFrameCount,
            submittedFrames: submittedFrames,
            callbackFrames: snapshot.callbackFrames,
            outputSampleBuffers: outputFrames,
            failedFrames: failedFrames,
            droppedFrames: snapshot.droppedFrames,
            keyFrames: snapshot.keyFrames,
            reorderedFrames: snapshot.reorderedFrames,
            totalEncodedBytes: snapshot.totalEncodedBytes,
            wallClockSeconds: wallClockSeconds,
            throughputFramesPerSecond: throughput,
            firstCallbackLatencyMilliseconds: snapshot.latenciesMilliseconds.first,
            meanCallbackLatencyMilliseconds: meanLatency,
            p95CallbackLatencyMilliseconds: percentile95(snapshot.latenciesMilliseconds),
            maximumInFlightFrames: maximumInFlightFrames,
            measuredBitRate: measuredBitRate
        )

        var evidence: [EvidenceLevel] = [.sessionCreated]
        let producedBitstream = outputFrames > 0
            && snapshot.outputFormat != nil
            && snapshot.totalEncodedBytes > 0
        if producedBitstream {
            evidence.append(.bitstreamProduced)
        }
        if hardwareStatus == noErr, usesHardwareEncoder == true {
            evidence.append(.hardwareRuntimeProperty)
        }
        let reachedSustainedTarget = !cancelled
            && submittedFrames == configuration.requestedFrameCount
            && outputFrames == configuration.requestedFrameCount
            && snapshot.callbackFrames == configuration.requestedFrameCount
            && failedFrames == 0
            && snapshot.droppedFrames == 0
            && throughput >= Double(configuration.framesPerSecond)
        if reachedSustainedTarget {
            evidence.append(.sustainedThroughput)
        }

        return SustainedEncodingResult(
            configuration: configuration,
            sessionCreation: sessionCreation,
            propertyWrites: propertyWrites,
            prepare: prepare,
            pixelBufferPoolAvailable: pixelBufferPoolAvailable,
            completeFrames: completeFrames,
            hardwarePropertyQuery: APICallResult(
                function: "VTSessionCopyProperty(UsingHardwareAcceleratedVideoEncoder)",
                status: hardwareStatus
            ),
            usesHardwareEncoder: usesHardwareEncoder,
            metrics: metrics,
            outputFormat: snapshot.outputFormat,
            callbackStatuses: callbackStatuses,
            evidence: evidence,
            cancelled: cancelled
        )
    }

    private static func failedResult(
        configuration: SustainedEncodingConfiguration,
        sessionCreation: APICallResult,
        cancelled: Bool
    ) -> SustainedEncodingResult {
        SustainedEncodingResult(
            configuration: configuration,
            sessionCreation: sessionCreation,
            propertyWrites: [],
            prepare: nil,
            pixelBufferPoolAvailable: false,
            completeFrames: nil,
            hardwarePropertyQuery: nil,
            usesHardwareEncoder: nil,
            metrics: SustainedEncodingMetrics(
                requestedFrames: configuration.requestedFrameCount,
                submittedFrames: 0,
                callbackFrames: 0,
                outputSampleBuffers: 0,
                failedFrames: 1,
                droppedFrames: 0,
                keyFrames: 0,
                reorderedFrames: 0,
                totalEncodedBytes: 0,
                wallClockSeconds: 0,
                throughputFramesPerSecond: 0,
                firstCallbackLatencyMilliseconds: nil,
                meanCallbackLatencyMilliseconds: nil,
                p95CallbackLatencyMilliseconds: nil,
                maximumInFlightFrames: 0,
                measuredBitRate: 0
            ),
            outputFormat: nil,
            callbackStatuses: [sessionCreation],
            evidence: [],
            cancelled: cancelled
        )
    }

    private static func fill(_ pixelBuffer: CVPixelBuffer, frameIndex: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else {
            return
        }

        if let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let movingStripeStart = (frameIndex * max(1, width / 60)) % width
            let movingStripeEnd = min(width, movingStripeStart + max(8, width / 16))

            for row in 0..<height {
                let bytes = lumaBase
                    .advanced(by: row * bytesPerRow)
                    .assumingMemoryBound(to: UInt8.self)
                memset(bytes, Int32(48 + (frameIndex % 80)), width)
                memset(
                    bytes.advanced(by: movingStripeStart),
                    208,
                    movingStripeEnd - movingStripeStart
                )
            }
        }

        if let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            memset(chromaBase, 128, height * bytesPerRow)
        }
    }

    private static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }
    }

    fileprivate static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", value)
    }
}

private final class FrameSubmission {
    let index: Int
    let submittedAt: TimeInterval

    init(index: Int, submittedAt: TimeInterval) {
        self.index = index
        self.submittedAt = submittedAt
    }
}

private struct EncodingCallbackSnapshot {
    let callbackFrames: Int
    let outputSampleBuffers: Int
    let droppedFrames: Int
    let keyFrames: Int
    let reorderedFrames: Int
    let totalEncodedBytes: Int
    let latenciesMilliseconds: [Double]
    let outputFormat: EncodedFormatSummary?
    let callbackStatuses: [APICallResult]
    let submissionFailures: [APICallResult]
}

private final class EncodingCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var submissions: [FrameSubmission] = []
    private var callbackFrames = 0
    private var outputSampleBuffers = 0
    private var droppedFrames = 0
    private var keyFrames = 0
    private var reorderedFrames = 0
    private var totalEncodedBytes = 0
    private var latenciesMilliseconds: [Double] = []
    private var outputFormat: EncodedFormatSummary?
    private var callbackStatuses: [APICallResult] = []
    private var submissionFailures: [APICallResult] = []

    var callbackFrameCount: Int {
        lock.withLock { callbackFrames }
    }

    func retain(_ submission: FrameSubmission) {
        lock.withLock {
            submissions.append(submission)
        }
    }

    func recordSubmissionFailure(status: OSStatus, function: String) {
        lock.withLock {
            submissionFailures.append(APICallResult(function: function, status: status))
        }
    }

    func recordCallback(
        submission: FrameSubmission?,
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        lock.withLock {
            callbackFrames += 1
            callbackStatuses.append(
                APICallResult(
                    function: "VTCompressionOutputCallback[\(submission?.index ?? -1)]",
                    status: status
                )
            )

            if let submission {
                latenciesMilliseconds.append(
                    max(0, ProcessInfo.processInfo.systemUptime - submission.submittedAt) * 1_000
                )
            }
            if infoFlags.contains(.frameDropped) {
                droppedFrames += 1
            }

            guard
                status == noErr,
                let sampleBuffer,
                CMSampleBufferIsValid(sampleBuffer),
                CMSampleBufferDataIsReady(sampleBuffer)
            else {
                return
            }

            outputSampleBuffers += 1
            if let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                totalEncodedBytes += CMBlockBufferGetDataLength(dataBuffer)
            }

            let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let decode = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
            if decode.isValid, presentation.isValid, decode != presentation {
                reorderedFrames += 1
            }

            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [NSDictionary]
            let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            if !isNotSync {
                keyFrames += 1
            }

            if outputFormat == nil, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                let mediaSubType = CMFormatDescriptionGetMediaSubType(format)
                let extensions = CMFormatDescriptionGetExtensions(format)
                outputFormat = EncodedFormatSummary(
                    mediaSubType: mediaSubType,
                    mediaSubTypeFourCC: SustainedEncodingProbe.fourCC(mediaSubType),
                    width: dimensions.width,
                    height: dimensions.height,
                    extensions: extensions.map { JSONValue(foundationValue: $0 as NSDictionary) }
                )
            }
        }
    }

    func snapshot() -> EncodingCallbackSnapshot {
        lock.withLock {
            EncodingCallbackSnapshot(
                callbackFrames: callbackFrames,
                outputSampleBuffers: outputSampleBuffers,
                droppedFrames: droppedFrames,
                keyFrames: keyFrames,
                reorderedFrames: reorderedFrames,
                totalEncodedBytes: totalEncodedBytes,
                latenciesMilliseconds: latenciesMilliseconds,
                outputFormat: outputFormat,
                callbackStatuses: callbackStatuses,
                submissionFailures: submissionFailures
            )
        }
    }
}

private let compressionOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    sourceFrameRefCon,
    status,
    infoFlags,
    sampleBuffer in
    guard let outputCallbackRefCon else {
        return
    }
    let context = Unmanaged<EncodingCallbackContext>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    let submission = sourceFrameRefCon.map {
        Unmanaged<FrameSubmission>.fromOpaque($0).takeUnretainedValue()
    }
    context.recordCallback(
        submission: submission,
        status: status,
        infoFlags: infoFlags,
        sampleBuffer: sampleBuffer
    )
}
