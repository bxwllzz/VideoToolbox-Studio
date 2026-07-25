import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum VideoTranscoder {
    static func transcode(
        sourceURL: URL,
        settings: TranscodeSettings,
        buildReport: BuildReport,
        cancellationToken: EncodingCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscodeResult {
        try settings.validate()
        try checkCancellation(cancellationToken)

        let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let thermalStateBefore = thermalDescription(ProcessInfo.processInfo.thermalState)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let inputSummary = try await MediaInspector.inspect(sourceURL)
        guard inputSummary.videoTracks.count == 1 else {
            if inputSummary.videoTracks.isEmpty {
                throw TranscodeError.unsupportedInput("没有找到视频轨道。")
            }
            throw TranscodeError.multipleVideoTracks(inputSummary.videoTracks.count)
        }

        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.load(.tracks)
        let videoTracks = tracks.filter { $0.mediaType == .video }
        guard let videoTrack = videoTracks.first else {
            throw TranscodeError.unsupportedInput("没有找到视频轨道。")
        }
        let nonVideoTracks = tracks.filter { $0.mediaType != .video }
        let sourceVideoSummary = inputSummary.videoTracks[0]
        let isHDR = sourceVideoSummary.color?.isHDR == true
        let codecType = try settings.targetCodec.resolvedCodecType(isHDR: isHDR)
        let resolvedSettings = resolve(
            settings: settings,
            sourceVideo: sourceVideoSummary,
            codecType: codecType,
            isHDR: isHDR
        )

        let outputURL = try makeOutputURL(
            sourceURL: sourceURL,
            codecType: codecType
        )
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        do {
            let runtimeResult = try await encode(
                asset: asset,
                videoTrack: videoTrack,
                nonVideoTracks: nonVideoTracks,
                outputURL: outputURL,
                resolvedSettings: resolvedSettings,
                sourceColor: sourceVideoSummary.color,
                cancellationToken: cancellationToken,
                sourceDuration: inputSummary.durationSeconds,
                progress: progress
            )

            try copyFileDates(from: sourceURL, to: outputURL)
            let outputSummary = try await MediaInspector.inspect(outputURL)
            let checks = preservationChecks(
                input: inputSummary,
                output: outputSummary,
                expectedCodec: codecType,
                usesHardwareEncoder: runtimeResult.usesHardwareEncoder
            )
            let failedChecks = checks.filter { !$0.passed }.map(\.name)
            guard failedChecks.isEmpty else {
                throw TranscodeError.verificationFailed(failedChecks)
            }

            let wallClockSeconds = max(
                0,
                ProcessInfo.processInfo.systemUptime - startedAt
            )
            let inputBytes = inputSummary.fileSize
            let outputBytes = outputSummary.fileSize
            let ratio = inputBytes > 0
                ? Double(outputBytes) / Double(inputBytes)
                : 0
            let metrics = TranscodeMetrics(
                decodedVideoFrames: runtimeResult.decodedVideoFrames,
                submittedVideoFrames: runtimeResult.submittedVideoFrames,
                encodedVideoFrames: runtimeResult.encodedVideoFrames,
                droppedVideoFrames: runtimeResult.droppedVideoFrames,
                copiedNonVideoSamples: runtimeResult.copiedNonVideoSamples,
                wallClockSeconds: wallClockSeconds,
                sourceDurationSeconds: inputSummary.durationSeconds,
                processingFramesPerSecond: wallClockSeconds > 0
                    ? Double(runtimeResult.encodedVideoFrames) / wallClockSeconds
                    : 0,
                inputBytes: inputBytes,
                outputBytes: outputBytes,
                outputToInputSizeRatio: ratio
            )
            let report = TranscodeReport(
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
                sourceFileName: sourceURL.lastPathComponent,
                outputFileName: outputURL.lastPathComponent,
                requestedSettings: settings,
                resolvedSettings: resolvedSettings,
                input: inputSummary,
                output: outputSummary,
                propertyWrites: runtimeResult.propertyWrites,
                hardwarePropertyQuery: runtimeResult.hardwarePropertyQuery,
                usesHardwareEncoder: runtimeResult.usesHardwareEncoder,
                metrics: metrics,
                preservationChecks: checks,
                thermalStateBefore: thermalStateBefore,
                thermalStateAfter: thermalDescription(ProcessInfo.processInfo.thermalState)
            )
            let reportURL = try TranscodeReportExporter.write(
                report,
                beside: outputURL
            )
            progress(1)
            return TranscodeResult(
                outputURL: outputURL,
                reportURL: reportURL,
                report: report
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func resolve(
        settings: TranscodeSettings,
        sourceVideo: MediaTrackSummary,
        codecType: CMVideoCodecType,
        isHDR: Bool
    ) -> ResolvedTranscodeSettings {
        let sourceBitRate = max(100_000, Int(sourceVideo.estimatedDataRate.rounded()))
        let averageBitRate: Int?
        let quality: Double?
        switch settings.rateControl {
        case .sourceRatio:
            averageBitRate = max(
                100_000,
                Int(Double(sourceBitRate) * settings.sourceBitRateRatio)
            )
            quality = nil
        case .fixedBitRate:
            averageBitRate = settings.fixedBitRate
            quality = nil
        case .quality:
            averageBitRate = nil
            quality = settings.quality
        }

        let dataRateLimits = averageBitRate.flatMap { bitRate in
            settings.dataRateLimitMultiplier.map { multiplier in
                [Double(bitRate) * multiplier / 8, 1]
            }
        }
        let frameRate = max(1, sourceVideo.nominalFrameRate)
        let keyFrameInterval = settings.maxKeyFrameInterval > 0
            ? settings.maxKeyFrameInterval
            : max(1, Int((frameRate * settings.maxKeyFrameIntervalDuration).rounded()))
        let profileLevel: String
        let pixelFormat: OSType
        if codecType == kCMVideoCodecType_HEVC {
            if isHDR {
                profileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel as String
                pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            } else {
                profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel as String
                pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
        } else {
            profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        return ResolvedTranscodeSettings(
            codecType: codecType,
            codecFourCC: mediaFourCC(codecType),
            profileLevel: profileLevel,
            pixelFormat: pixelFormat,
            averageBitRate: averageBitRate,
            quality: quality,
            dataRateLimits: dataRateLimits,
            expectedFrameRate: frameRate,
            maxKeyFrameInterval: keyFrameInterval,
            maxKeyFrameIntervalDuration: settings.maxKeyFrameIntervalDuration,
            allowFrameReordering: settings.allowFrameReordering,
            realTime: settings.realTime,
            prioritizeEncodingSpeedOverQuality: settings.prioritizeEncodingSpeedOverQuality
        )
    }

    private static func encode(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        nonVideoTracks: [AVAssetTrack],
        outputURL: URL,
        resolvedSettings: ResolvedTranscodeSettings,
        sourceColor: MediaColorSummary?,
        cancellationToken: EncodingCancellationToken,
        sourceDuration: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RuntimeTranscodeResult {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw TranscodeError.unsupportedInput(error.localizedDescription)
        }

        writer.metadata = try await asset.load(.metadata)
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    resolvedSettings.pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw TranscodeError.unsupportedInput("无法为视频轨道创建解码输出。")
        }
        reader.add(videoOutput)

        let videoWriterInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil
        )
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = try await videoTrack.load(.preferredTransform)
        videoWriterInput.metadata = try await videoTrack.load(.metadata)
        guard writer.canAdd(videoWriterInput) else {
            throw TranscodeError.writerFailed("无法添加压缩视频轨道。")
        }
        writer.add(videoWriterInput)

        var passthroughChannels: [PassthroughChannel] = []
        for track in nonVideoTracks {
            let formatDescriptions = try await track.load(.formatDescriptions)
            guard let formatHint = formatDescriptions.first else {
                throw TranscodeError.cannotPreserveTrack(
                    "\(track.mediaType.rawValue)#\(track.trackID)：缺少格式描述"
                )
            }
            let readerOutput = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: nil
            )
            readerOutput.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOutput) else {
                throw TranscodeError.cannotPreserveTrack(
                    "\(track.mediaType.rawValue)#\(track.trackID)：无法读取压缩样本"
                )
            }

            let writerInput = AVAssetWriterInput(
                mediaType: track.mediaType,
                outputSettings: nil,
                sourceFormatHint: formatHint
            )
            writerInput.expectsMediaDataInRealTime = false
            writerInput.languageCode = try? await track.load(.languageCode)
            writerInput.extendedLanguageTag = try? await track.load(.extendedLanguageTag)
            writerInput.metadata = try await track.load(.metadata)
            guard writer.canAdd(writerInput) else {
                throw TranscodeError.cannotPreserveTrack(
                    "\(track.mediaType.rawValue)#\(track.trackID)：MOV 不接受原压缩格式"
                )
            }
            reader.add(readerOutput)
            writer.add(writerInput)
            passthroughChannels.append(
                PassthroughChannel(
                    readerOutput: readerOutput,
                    writerInput: writerInput
                )
            )
        }

        let allTracks = [videoTrack] + nonVideoTracks
        var sessionStartTime = CMTime.zero
        for track in allTracks {
            let start = try await track.load(.timeRange).start
            if start.isNumeric,
               (sessionStartTime == .zero || CMTimeCompare(start, sessionStartTime) < 0)
            {
                sessionStartTime = start
            }
        }

        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting 返回 false"
            )
        }
        writer.startSession(atSourceTime: sessionStartTime)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw TranscodeError.readerFailed(
                reader.error?.localizedDescription ?? "startReading 返回 false"
            )
        }

        let callbackContext = TranscodeCallbackContext(
            writerInput: videoWriterInput,
            writer: writer,
            cancellationToken: cancellationToken
        )
        var compressionSession: VTCompressionSession?
        let dimensions = try await videoTrack.load(.naturalSize)
        let width = Int32(abs(dimensions.width.rounded()))
        let height = Int32(abs(dimensions.height.rounded()))
        guard width > 0, height > 0 else {
            reader.cancelReading()
            writer.cancelWriting()
            throw TranscodeError.unsupportedInput("视频分辨率无效。")
        }

        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ] as CFDictionary
        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: resolvedSettings.pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary,
        ] as CFDictionary
        let sessionStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: resolvedSettings.codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: transcodeOutputCallback,
            refcon: Unmanaged.passUnretained(callbackContext).toOpaque(),
            compressionSessionOut: &compressionSession
        )
        guard sessionStatus == noErr, let compressionSession else {
            reader.cancelReading()
            writer.cancelWriting()
            throw TranscodeError.compressionSessionFailed(sessionStatus)
        }
        defer {
            VTCompressionSessionInvalidate(compressionSession)
        }

        let propertyWrites = try configure(
            compressionSession,
            settings: resolvedSettings,
            sourceColor: sourceColor
        )
        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(
            compressionSession
        )
        guard prepareStatus == noErr else {
            reader.cancelReading()
            writer.cancelWriting()
            throw TranscodeError.frameEncodingFailed(prepareStatus)
        }

        var decodedVideoFrames = 0
        var submittedVideoFrames = 0
        var copiedNonVideoSamples = 0
        var lastPresentationTime = sessionStartTime

        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            do {
                try checkCancellation(cancellationToken)
                try callbackContext.throwIfFailed()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw TranscodeError.unsupportedInput(
                        "解码输出没有 CVPixelBuffer。"
                    )
                }

                decodedVideoFrames += 1
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(
                    sampleBuffer
                )
                lastPresentationTime = presentationTime
                var duration = CMSampleBufferGetDuration(sampleBuffer)
                if !duration.isNumeric || duration == .zero {
                    duration = CMTime(
                        seconds: 1 / resolvedSettings.expectedFrameRate,
                        preferredTimescale: 60_000
                    )
                }
                var infoFlags = VTEncodeInfoFlags()
                let encodeStatus = VTCompressionSessionEncodeFrame(
                    compressionSession,
                    imageBuffer: pixelBuffer,
                    presentationTimeStamp: presentationTime,
                    duration: duration,
                    frameProperties: nil,
                    sourceFrameRefcon: nil,
                    infoFlagsOut: &infoFlags
                )
                guard encodeStatus == noErr else {
                    throw TranscodeError.frameEncodingFailed(encodeStatus)
                }
                submittedVideoFrames += 1

                for channel in passthroughChannels {
                    copiedNonVideoSamples += try channel.drain(
                        through: CMTimeAdd(presentationTime, duration),
                        cancellationToken: cancellationToken,
                        writer: writer
                    )
                }

                if sourceDuration > 0, presentationTime.isNumeric {
                    let completed = max(
                        0,
                        CMTimeGetSeconds(CMTimeSubtract(
                            presentationTime,
                            sessionStartTime
                        ))
                    )
                    progress(min(0.98, completed / sourceDuration))
                }
            } catch {
                reader.cancelReading()
                writer.cancelWriting()
                throw error
            }
        }

        let completeStatus = VTCompressionSessionCompleteFrames(
            compressionSession,
            untilPresentationTimeStamp: .invalid
        )
        guard completeStatus == noErr else {
            reader.cancelReading()
            writer.cancelWriting()
            throw TranscodeError.frameEncodingFailed(completeStatus)
        }
        try callbackContext.throwIfFailed()
        videoWriterInput.markAsFinished()

        for channel in passthroughChannels {
            copiedNonVideoSamples += try channel.drain(
                through: .positiveInfinity,
                cancellationToken: cancellationToken,
                writer: writer
            )
            channel.writerInput.markAsFinished()
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw TranscodeError.readerFailed(
                reader.error?.localizedDescription ?? "未知 AVAssetReader 错误"
            )
        }
        try checkCancellation(cancellationToken)

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription ?? "finishWriting 未完成"
            )
        }

        var hardwareValue: CFTypeRef?
        let hardwareStatus = VTSessionCopyProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: nil,
            valueOut: &hardwareValue
        )
        let usesHardware = (hardwareValue as? NSNumber)?.boolValue == true
        guard hardwareStatus == noErr, usesHardware else {
            throw TranscodeError.writerFailed("运行时没有确认严格硬件编码器。")
        }
        let callbackSnapshot = callbackContext.snapshot()

        if submittedVideoFrames == 0 || callbackSnapshot.encodedFrames == 0 {
            throw TranscodeError.unsupportedInput("视频没有产生可封装的帧。")
        }
        if callbackSnapshot.encodedFrames != submittedVideoFrames {
            throw TranscodeError.writerFailed(
                "提交 \(submittedVideoFrames) 帧，但仅封装 "
                    + "\(callbackSnapshot.encodedFrames) 帧。"
            )
        }
        _ = lastPresentationTime

        return RuntimeTranscodeResult(
            propertyWrites: propertyWrites,
            hardwarePropertyQuery: APICallResult(
                function: "VTSessionCopyProperty(UsingHardwareAcceleratedVideoEncoder)",
                status: hardwareStatus
            ),
            usesHardwareEncoder: usesHardware,
            decodedVideoFrames: decodedVideoFrames,
            submittedVideoFrames: submittedVideoFrames,
            encodedVideoFrames: callbackSnapshot.encodedFrames,
            droppedVideoFrames: callbackSnapshot.droppedFrames,
            copiedNonVideoSamples: copiedNonVideoSamples
        )
    }

    private static func configure(
        _ session: VTCompressionSession,
        settings: ResolvedTranscodeSettings,
        sourceColor: MediaColorSummary?
    ) throws -> [PropertyWriteResult] {
        var writes: [PropertyWriteResult] = []

        try appendProperty(
            to: &writes,
            session: session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            name: "ProfileLevel",
            value: settings.profileLevel as CFString
        )
        try appendProperty(
            to: &writes,
            session: session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            name: "ExpectedFrameRate",
            value: NSNumber(value: settings.expectedFrameRate)
        )
        if let averageBitRate = settings.averageBitRate {
            try appendProperty(
                to: &writes,
                session: session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                name: "AverageBitRate",
                value: NSNumber(value: averageBitRate)
            )
        }
        if let quality = settings.quality {
            try appendProperty(
                to: &writes,
                session: session,
                key: kVTCompressionPropertyKey_Quality,
                name: "Quality",
                value: NSNumber(value: quality)
            )
        }
        if let limits = settings.dataRateLimits {
            let values = limits.map(NSNumber.init(value:)) as CFArray
            try appendProperty(
                to: &writes,
                session: session,
                key: kVTCompressionPropertyKey_DataRateLimits,
                name: "DataRateLimits",
                value: values
            )
        }
        try appendProperty(
            to: &writes,
            session: session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            name: "MaxKeyFrameInterval",
            value: NSNumber(value: settings.maxKeyFrameInterval)
        )
        try appendProperty(
            to: &writes,
            session: session,
            key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
            name: "MaxKeyFrameIntervalDuration",
            value: NSNumber(value: settings.maxKeyFrameIntervalDuration)
        )
        try appendProperty(
            to: &writes,
            session: session,
            key: kVTCompressionPropertyKey_AllowFrameReordering,
            name: "AllowFrameReordering",
            value: settings.allowFrameReordering ? kCFBooleanTrue : kCFBooleanFalse
        )
        try appendProperty(
            to: &writes,
            session: session,
            key: kVTCompressionPropertyKey_RealTime,
            name: "RealTime",
            value: settings.realTime ? kCFBooleanTrue : kCFBooleanFalse
        )
        try appendProperty(
            to: &writes,
            session: session,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            name: "PrioritizeEncodingSpeedOverQuality",
            value: settings.prioritizeEncodingSpeedOverQuality
                ? kCFBooleanTrue
                : kCFBooleanFalse
        )

        if let colorPrimaries = sourceColor?.colorPrimaries {
            try appendProperty(
                to: &writes,
                session: session,
                key: kVTCompressionPropertyKey_ColorPrimaries,
                name: "ColorPrimaries",
                value: colorPrimaries as CFString
            )
        }
        if let transferFunction = sourceColor?.transferFunction {
            try appendProperty(
                to: &writes,
                session: session,
                key: kVTCompressionPropertyKey_TransferFunction,
                name: "TransferFunction",
                value: transferFunction as CFString
            )
        }
        if let yCbCrMatrix = sourceColor?.yCbCrMatrix {
            try appendProperty(
                to: &writes,
                session: session,
                key: kVTCompressionPropertyKey_YCbCrMatrix,
                name: "YCbCrMatrix",
                value: yCbCrMatrix as CFString
            )
        }
        return writes
    }

    private static func appendProperty(
        to writes: inout [PropertyWriteResult],
        session: VTCompressionSession,
        key: CFString,
        name: String,
        value: CFTypeRef
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        writes.append(
            PropertyWriteResult(
                key: name,
                requestedValue: JSONValue(foundationValue: value),
                status: APICallResult(
                    function: "VTSessionSetProperty(\(name))",
                    status: status
                )
            )
        )
        guard status == noErr else {
            throw TranscodeError.propertyRejected(name, status)
        }
    }

    private static func preservationChecks(
        input: MediaAssetSummary,
        output: MediaAssetSummary,
        expectedCodec: CMVideoCodecType,
        usesHardwareEncoder: Bool
    ) -> [PreservationCheck] {
        guard let inputVideo = input.videoTracks.first,
              let outputVideo = output.videoTracks.first
        else {
            return [
                PreservationCheck(
                    name: "视频轨道",
                    passed: false,
                    inputValue: "\(input.videoTracks.count)",
                    outputValue: "\(output.videoTracks.count)",
                    detail: "输入和输出都必须恰好包含一条视频轨道。"
                ),
            ]
        }

        let frameTolerance = max(
            0.05,
            1 / max(1, inputVideo.nominalFrameRate)
        )
        let durationPassed = abs(
            input.durationSeconds - output.durationSeconds
        ) <= frameTolerance
        let nonVideoInput = inventory(input.nonVideoTracks)
        let nonVideoOutput = inventory(output.nonVideoTracks)
        let inputMetadata = Set(input.metadata)
        let outputMetadata = Set(output.metadata)
        let missingMetadata = inputMetadata.subtracting(outputMetadata)

        return [
            PreservationCheck(
                name: "严格硬件编码",
                passed: usesHardwareEncoder,
                inputValue: "要求",
                outputValue: usesHardwareEncoder ? "已确认" : "未确认",
                detail: "运行时属性必须确认使用硬件编码器。"
            ),
            PreservationCheck(
                name: "视频轨道数量",
                passed: output.videoTracks.count == 1,
                inputValue: "\(input.videoTracks.count)",
                outputValue: "\(output.videoTracks.count)",
                detail: "不允许静默丢弃或新增视频轨道。"
            ),
            PreservationCheck(
                name: "目标视频编码",
                passed: outputVideo.codecType == expectedCodec,
                inputValue: mediaFourCC(expectedCodec),
                outputValue: outputVideo.codecFourCC,
                detail: "重新打开输出文件读取实际 Codec。"
            ),
            PreservationCheck(
                name: "显示分辨率",
                passed: nearlyEqual(
                    inputVideo.naturalWidth,
                    outputVideo.naturalWidth
                ) && nearlyEqual(
                    inputVideo.naturalHeight,
                    outputVideo.naturalHeight
                ),
                inputValue: dimensions(inputVideo),
                outputValue: dimensions(outputVideo),
                detail: "不缩放、不裁剪视频像素。"
            ),
            PreservationCheck(
                name: "方向矩阵",
                passed: inputVideo.preferredTransform == outputVideo.preferredTransform,
                inputValue: String(describing: inputVideo.preferredTransform),
                outputValue: String(describing: outputVideo.preferredTransform),
                detail: "通过轨道 transform 保留拍摄方向。"
            ),
            PreservationCheck(
                name: "时长与时间轴",
                passed: durationPassed,
                inputValue: String(format: "%.6f s", input.durationSeconds),
                outputValue: String(format: "%.6f s", output.durationSeconds),
                detail: "允许不超过一帧或 50 ms 的封装舍入误差。"
            ),
            PreservationCheck(
                name: "色彩与 HDR 描述",
                passed: inputVideo.color == outputVideo.color,
                inputValue: String(describing: inputVideo.color),
                outputValue: String(describing: outputVideo.color),
                detail: "色域、传递函数、矩阵、位深和 HDR 静态元数据逐项一致。"
            ),
            PreservationCheck(
                name: "非视频轨道直通",
                passed: nonVideoInput == nonVideoOutput,
                inputValue: nonVideoInput.description,
                outputValue: nonVideoOutput.description,
                detail: "音频、字幕、隐藏字幕、时间码和定时元数据按压缩样本直通。"
            ),
            PreservationCheck(
                name: "容器元数据",
                passed: missingMetadata.isEmpty,
                inputValue: "\(input.metadata.count) 项",
                outputValue: "\(output.metadata.count) 项",
                detail: missingMetadata.isEmpty
                    ? "输入元数据均可在输出中重新读取。"
                    : "缺少 \(missingMetadata.count) 项输入元数据。"
            ),
            PreservationCheck(
                name: "文件创建时间",
                passed: input.creationDate == nil
                    || input.creationDate == output.creationDate,
                inputValue: input.creationDate ?? "unknown",
                outputValue: output.creationDate ?? "unknown",
                detail: "输出文件尽力继承源文件创建时间。"
            ),
        ]
    }

    private static func inventory(
        _ tracks: [MediaTrackSummary]
    ) -> [String: Int] {
        Dictionary(
            grouping: tracks,
            by: { "\($0.mediaType)|\($0.codecFourCC)" }
        )
        .mapValues(\.count)
    }

    private static func dimensions(_ track: MediaTrackSummary) -> String {
        let width = track.naturalWidth ?? 0
        let height = track.naturalHeight ?? 0
        return "\(Int(width.rounded()))×\(Int(height.rounded()))"
    }

    private static func nearlyEqual(_ lhs: Double?, _ rhs: Double?) -> Bool {
        guard let lhs, let rhs else {
            return lhs == nil && rhs == nil
        }
        return abs(lhs - rhs) < 0.5
    }

    private static func makeOutputURL(
        sourceURL: URL,
        codecType: CMVideoCodecType
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoToolboxStudio", isDirectory: true)
            .appendingPathComponent("Transcoded", isDirectory: true)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let codec = codecType == kCMVideoCodecType_HEVC ? "HEVC" : "H264"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let fileName = "\(baseName)-\(codec)-\(formatter.string(from: Date())).mov"
        return directory.appendingPathComponent(fileName)
    }

    private static func copyFileDates(from source: URL, to output: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: source.path
        )
        var outputAttributes: [FileAttributeKey: Any] = [:]
        if let creationDate = attributes[.creationDate] {
            outputAttributes[.creationDate] = creationDate
        }
        if let modificationDate = attributes[.modificationDate] {
            outputAttributes[.modificationDate] = modificationDate
        }
        if !outputAttributes.isEmpty {
            try FileManager.default.setAttributes(
                outputAttributes,
                ofItemAtPath: output.path
            )
        }
    }

    private static func checkCancellation(
        _ cancellationToken: EncodingCancellationToken
    ) throws {
        if cancellationToken.isCancelled || Task.isCancelled {
            throw TranscodeError.cancelled
        }
    }

    private static func thermalDescription(
        _ state: ProcessInfo.ThermalState
    ) -> String {
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
}

private struct RuntimeTranscodeResult {
    let propertyWrites: [PropertyWriteResult]
    let hardwarePropertyQuery: APICallResult
    let usesHardwareEncoder: Bool
    let decodedVideoFrames: Int
    let submittedVideoFrames: Int
    let encodedVideoFrames: Int
    let droppedVideoFrames: Int
    let copiedNonVideoSamples: Int
}

private final class PassthroughChannel {
    let readerOutput: AVAssetReaderTrackOutput
    let writerInput: AVAssetWriterInput
    private var pendingSample: CMSampleBuffer?
    private var reachedEnd = false

    init(
        readerOutput: AVAssetReaderTrackOutput,
        writerInput: AVAssetWriterInput
    ) {
        self.readerOutput = readerOutput
        self.writerInput = writerInput
    }

    func drain(
        through limit: CMTime,
        cancellationToken: EncodingCancellationToken,
        writer: AVAssetWriter
    ) throws -> Int {
        var copied = 0
        while !reachedEnd {
            if pendingSample == nil {
                pendingSample = readerOutput.copyNextSampleBuffer()
                if pendingSample == nil {
                    reachedEnd = true
                    break
                }
            }
            guard let sample = pendingSample else {
                break
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            if limit != .positiveInfinity,
               presentationTime.isNumeric,
               CMTimeCompare(presentationTime, limit) > 0
            {
                break
            }
            try waitUntilReady(
                writerInput,
                cancellationToken: cancellationToken,
                writer: writer
            )
            guard writerInput.append(sample) else {
                throw TranscodeError.writerFailed(
                    writer.error?.localizedDescription
                        ?? "非视频轨道 append 返回 false"
                )
            }
            copied += 1
            pendingSample = nil
        }
        return copied
    }
}

private struct TranscodeCallbackSnapshot {
    let encodedFrames: Int
    let droppedFrames: Int
}

private final class TranscodeCallbackContext: @unchecked Sendable {
    private let writerInput: AVAssetWriterInput
    private let writer: AVAssetWriter
    private let cancellationToken: EncodingCancellationToken
    private let lock = NSLock()
    private var encodedFrames = 0
    private var droppedFrames = 0
    private var failure: TranscodeError?

    init(
        writerInput: AVAssetWriterInput,
        writer: AVAssetWriter,
        cancellationToken: EncodingCancellationToken
    ) {
        self.writerInput = writerInput
        self.writer = writer
        self.cancellationToken = cancellationToken
    }

    func receive(
        status: OSStatus,
        infoFlags: VTEncodeInfoFlags,
        sampleBuffer: CMSampleBuffer?
    ) {
        lock.withLock {
            guard failure == nil else {
                return
            }
            if infoFlags.contains(.frameDropped) {
                droppedFrames += 1
            }
            guard status == noErr else {
                failure = .frameEncodingFailed(status)
                return
            }
            guard let sampleBuffer,
                  CMSampleBufferIsValid(sampleBuffer),
                  CMSampleBufferDataIsReady(sampleBuffer)
            else {
                failure = .writerFailed("编码回调没有返回可用 Sample Buffer。")
                return
            }

            do {
                try waitUntilReady(
                    writerInput,
                    cancellationToken: cancellationToken,
                    writer: writer
                )
                guard writerInput.append(sampleBuffer) else {
                    throw TranscodeError.writerFailed(
                        writer.error?.localizedDescription
                            ?? "视频轨道 append 返回 false"
                    )
                }
                encodedFrames += 1
            } catch let error as TranscodeError {
                failure = error
            } catch {
                failure = .writerFailed(error.localizedDescription)
            }
        }
    }

    func throwIfFailed() throws {
        if let failure = lock.withLock({ failure }) {
            throw failure
        }
    }

    func snapshot() -> TranscodeCallbackSnapshot {
        lock.withLock {
            TranscodeCallbackSnapshot(
                encodedFrames: encodedFrames,
                droppedFrames: droppedFrames
            )
        }
    }
}

private func waitUntilReady(
    _ input: AVAssetWriterInput,
    cancellationToken: EncodingCancellationToken,
    writer: AVAssetWriter
) throws {
    while !input.isReadyForMoreMediaData {
        if cancellationToken.isCancelled {
            throw TranscodeError.cancelled
        }
        if writer.status == .failed || writer.status == .cancelled {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter 已停止"
            )
        }
        Thread.sleep(forTimeInterval: 0.002)
    }
}

private let transcodeOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    infoFlags,
    sampleBuffer in
    guard let outputCallbackRefCon else {
        return
    }
    let context = Unmanaged<TranscodeCallbackContext>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    context.receive(
        status: status,
        infoFlags: infoFlags,
        sampleBuffer: sampleBuffer
    )
}
