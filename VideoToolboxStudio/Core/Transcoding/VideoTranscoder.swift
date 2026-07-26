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
        try await transcode(
            source: .localFile(sourceURL),
            settings: settings,
            buildReport: buildReport,
            cancellationToken: cancellationToken,
            progress: progress
        )
    }

    static func transcode(
        source: TranscodeSource,
        settings: TranscodeSettings,
        buildReport: BuildReport,
        cancellationToken: EncodingCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscodeResult {
        try settings.validate()
        try checkCancellation(cancellationToken)
        reportStage("inspect-input", progress: 0.001, callback: progress)

        let hasSecurityScope =
            source.securityScopedURL?.startAccessingSecurityScopedResource() == true
        defer {
            if hasSecurityScope, let securityScopedURL = source.securityScopedURL {
                securityScopedURL.stopAccessingSecurityScopedResource()
            }
        }

        let thermalStateBefore = thermalDescription(ProcessInfo.processInfo.thermalState)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let inputSummary = try await MediaInspector.inspect(source)
        reportStage("input-inspected", progress: 0.005, callback: progress)
        guard inputSummary.videoTracks.count == 1 else {
            if inputSummary.videoTracks.isEmpty {
                throw TranscodeError.unsupportedInput("没有找到视频轨道。")
            }
            throw TranscodeError.multipleVideoTracks(inputSummary.videoTracks.count)
        }

        let asset = source.asset
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
            sourceFileName: source.fileName,
            codecType: codecType
        )
        let outputDirectory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)

        do {
            reportStage("prepare-pipeline", progress: 0.01, callback: progress)
            let runtimeResult = try await encode(
                asset: asset,
                videoTrack: videoTrack,
                nonVideoTracks: nonVideoTracks,
                outputURL: outputURL,
                resolvedSettings: resolvedSettings,
                sourceColor: sourceVideoSummary.color,
                cancellationToken: cancellationToken,
                sourceDuration: inputSummary.durationSeconds,
                timeRange: nil,
                progress: progress
            )

            reportStage("inspect-output", progress: 0.99, callback: progress)
            try applySourceDates(from: inputSummary, to: outputURL)
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
                videoEncodingPasses: runtimeResult.videoEncodingPasses,
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
                sourceFileName: source.fileName,
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
            print("VT_TRANSCODE_ERROR=\(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func estimateOutputSize(
        source: TranscodeSource,
        settings: TranscodeSettings,
        cancellationToken: EncodingCancellationToken,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscodeSizeEstimate {
        try settings.validate()
        try checkCancellation(cancellationToken)

        let inputSummary = try await MediaInspector.inspect(source)
        guard let sourceVideoSummary = inputSummary.videoTracks.first else {
            throw TranscodeError.unsupportedInput("没有找到视频轨道。")
        }
        guard inputSummary.durationSeconds.isFinite,
              inputSummary.durationSeconds > 0
        else {
            throw TranscodeError.unsupportedInput("视频时长无效，无法估算。")
        }

        let tracks = try await source.asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw TranscodeError.unsupportedInput("没有找到视频轨道。")
        }
        let nonVideoTracks = tracks.filter { $0.mediaType != .video }
        let isHDR = sourceVideoSummary.color?.isHDR == true
        let codecType = try settings.targetCodec.resolvedCodecType(isHDR: isHDR)
        let resolvedSettings = resolve(
            settings: settings,
            sourceVideo: sourceVideoSummary,
            codecType: codecType,
            isHDR: isHDR
        )

        let sampleDuration = min(5, inputSummary.durationSeconds)
        let sampleStart = sourceVideoSummary.timeRangeStartSeconds
            + max(0, (inputSummary.durationSeconds - sampleDuration) / 2)
        let sampleRange = CMTimeRange(
            start: CMTime(seconds: sampleStart, preferredTimescale: 60_000),
            duration: CMTime(seconds: sampleDuration, preferredTimescale: 60_000)
        )
        let outputURL = try makeEstimateOutputURL(
            sourceFileName: source.fileName,
            codecType: codecType
        )
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        _ = try await encode(
            asset: source.asset,
            videoTrack: videoTrack,
            nonVideoTracks: nonVideoTracks,
            outputURL: outputURL,
            resolvedSettings: resolvedSettings,
            sourceColor: sourceVideoSummary.color,
            cancellationToken: cancellationToken,
            sourceDuration: sampleDuration,
            timeRange: sampleRange,
            progress: progress
        )
        let sampleSummary = try await MediaInspector.inspect(outputURL)
        let measuredDuration = max(0.001, sampleSummary.durationSeconds)
        let estimatedBytes = Int64(
            (Double(sampleSummary.fileSize)
                * inputSummary.durationSeconds / measuredDuration).rounded()
        )
        let uncertainty = settings.rateControl == .quality ? 0.30 : 0.15
        let lowerBound = Int64(
            (Double(estimatedBytes) * (1 - uncertainty)).rounded()
        )
        let upperBound = Int64(
            (Double(estimatedBytes) * (1 + uncertainty)).rounded()
        )
        let ratio = inputSummary.fileSize > 0
            ? Double(estimatedBytes) / Double(inputSummary.fileSize)
            : nil

        return TranscodeSizeEstimate(
            sourceFileName: source.fileName,
            sampledDurationSeconds: measuredDuration,
            sourceDurationSeconds: inputSummary.durationSeconds,
            estimatedOutputBytes: estimatedBytes,
            lowerBoundBytes: max(0, lowerBound),
            upperBoundBytes: max(0, upperBound),
            estimatedOutputToInputRatio: ratio
        )
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

        let dataRateLimits = settings.dataRateLimitMultiplier.map { multiplier in
            let limitBaseBitRate = averageBitRate ?? sourceBitRate
            return [Double(limitBaseBitRate) * multiplier / 8, 1]
        }
        let frameRate = max(1, sourceVideo.nominalFrameRate)
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
            encodingQuality: settings.encodingQuality,
            profileLevel: profileLevel,
            pixelFormat: pixelFormat,
            averageBitRate: averageBitRate,
            quality: quality,
            dataRateLimits: dataRateLimits,
            expectedFrameRate: frameRate,
            maxKeyFrameInterval: settings.maxKeyFrameInterval,
            maxKeyFrameIntervalDuration: settings.maxKeyFrameIntervalDuration,
            allowFrameReordering: settings.allowFrameReordering,
            realTime: settings.realTime,
            prioritizeEncodingSpeedOverQuality: settings.prioritizeEncodingSpeedOverQuality
        )
    }

    private static func encode(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        nonVideoTracks: [AVAssetTrack],
        outputURL: URL,
        resolvedSettings: ResolvedTranscodeSettings,
        sourceColor: MediaColorSummary?,
        cancellationToken: EncodingCancellationToken,
        sourceDuration: Double,
        timeRange: CMTimeRange?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RuntimeTranscodeResult {
        guard resolvedSettings.encodingQuality == .refined else {
            return try await encodeSinglePass(
                asset: asset,
                videoTrack: videoTrack,
                nonVideoTracks: nonVideoTracks,
                outputURL: outputURL,
                resolvedSettings: resolvedSettings,
                sourceColor: sourceColor,
                cancellationToken: cancellationToken,
                sourceDuration: sourceDuration,
                timeRange: timeRange,
                progress: progress
            )
        }

        do {
            return try await encodeMultiPass(
                asset: asset,
                videoTrack: videoTrack,
                nonVideoTracks: nonVideoTracks,
                outputURL: outputURL,
                resolvedSettings: resolvedSettings,
                sourceColor: sourceColor,
                cancellationToken: cancellationToken,
                sourceDuration: sourceDuration,
                timeRange: timeRange,
                progress: progress
            )
        } catch let unavailable as MultiPassUnavailable {
            try? FileManager.default.removeItem(at: outputURL)
            var result = try await encodeSinglePass(
                asset: asset,
                videoTrack: videoTrack,
                nonVideoTracks: nonVideoTracks,
                outputURL: outputURL,
                resolvedSettings: resolvedSettings,
                sourceColor: sourceColor,
                cancellationToken: cancellationToken,
                sourceDuration: sourceDuration,
                timeRange: timeRange,
                progress: progress
            )
            result.propertyWrites.insert(unavailable.propertyWrite, at: 0)
            return result
        }
    }

    private static func encodeSinglePass(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        nonVideoTracks: [AVAssetTrack],
        outputURL: URL,
        resolvedSettings: ResolvedTranscodeSettings,
        sourceColor: MediaColorSummary?,
        cancellationToken: EncodingCancellationToken,
        sourceDuration: Double,
        timeRange: CMTimeRange?,
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
        if let timeRange {
            reader.timeRange = timeRange
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

        let dimensions = try await videoTrack.load(.naturalSize)
        let width = Int32(abs(dimensions.width.rounded()))
        let height = Int32(abs(dimensions.height.rounded()))
        guard width > 0, height > 0 else {
            throw TranscodeError.unsupportedInput("视频分辨率无效。")
        }
        var videoFormatHint: CMVideoFormatDescription?
        let formatHintStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: resolvedSettings.codecType,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &videoFormatHint
        )
        guard formatHintStatus == noErr, let videoFormatHint else {
            throw TranscodeError.writerFailed(
                "无法创建压缩视频格式提示：\(formatHintStatus)"
            )
        }
        let videoWriterInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormatHint
        )
        guard writer.canAdd(videoWriterInput) else {
            throw TranscodeError.writerFailed("无法添加压缩视频轨道。")
        }
        writer.add(videoWriterInput)
        // Pass-through inputs resolve their concrete helper from compressed
        // samples. Avoid helper-backed setters that reject the unknown state.
        videoWriterInput.transform = try await videoTrack.load(.preferredTransform)
        videoWriterInput.metadata = try await videoTrack.load(.metadata)

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
            guard writer.canAdd(writerInput) else {
                throw TranscodeError.cannotPreserveTrack(
                    "\(track.mediaType.rawValue)#\(track.trackID)：MOV 不接受原压缩格式"
                )
            }
            reader.add(readerOutput)
            writer.add(writerInput)
            writerInput.languageCode = try? await track.load(.languageCode)
            writerInput.extendedLanguageTag = try? await track.load(.extendedLanguageTag)
            writerInput.metadata = try await track.load(.metadata)
            passthroughChannels.append(
                PassthroughChannel(
                    readerOutput: readerOutput,
                    writerInput: writerInput
                )
            )
        }

        let sessionStartTime: CMTime
        if let timeRange {
            sessionStartTime = timeRange.start
        } else {
            let allTracks = [videoTrack] + nonVideoTracks
            var earliestStart = CMTime.zero
            for track in allTracks {
                let start = try await track.load(.timeRange).start
                if start.isNumeric,
                   (earliestStart == .zero
                       || CMTimeCompare(start, earliestStart) < 0)
                {
                    earliestStart = start
                }
            }
            sessionStartTime = earliestStart
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
        reportStage("reader-writer-started", progress: 0.02, callback: progress)

        let callbackContext = TranscodeCallbackContext()
        var compressionSession: VTCompressionSession?

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
        reportStage("encoder-prepared", progress: 0.03, callback: progress)

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
                if decodedVideoFrames == 1 || decodedVideoFrames.isMultiple(of: 30) {
                    print("VT_TRANSCODE_FRAME=\(decodedVideoFrames)")
                }

                let drainLimit = CMTimeAdd(presentationTime, duration)
                let drainResult = try drainReadySamples(
                    callbackContext: callbackContext,
                    videoWriterInput: videoWriterInput,
                    passthroughChannels: passthroughChannels,
                    through: drainLimit,
                    writer: writer,
                    cancellationToken: cancellationToken
                )
                copiedNonVideoSamples += drainResult.copiedNonVideoSamples
                copiedNonVideoSamples += try drainUntilVideoQueueHasCapacity(
                    callbackContext: callbackContext,
                    videoWriterInput: videoWriterInput,
                    passthroughChannels: passthroughChannels,
                    through: drainLimit,
                    writer: writer,
                    cancellationToken: cancellationToken
                )

                if sourceDuration > 0, presentationTime.isNumeric {
                    let completed = max(
                        0,
                        CMTimeGetSeconds(CMTimeSubtract(
                            presentationTime,
                            sessionStartTime
                        ))
                    )
                    progress(min(0.96, 0.03 + 0.93 * completed / sourceDuration))
                }
            } catch {
                reader.cancelReading()
                writer.cancelWriting()
                throw error
            }
        }

        reportStage("complete-frames", progress: 0.965, callback: progress)
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
        copiedNonVideoSamples += try drainAllRemainingSamples(
            callbackContext: callbackContext,
            videoWriterInput: videoWriterInput,
            passthroughChannels: passthroughChannels,
            writer: writer,
            cancellationToken: cancellationToken
        )
        reportStage("samples-drained", progress: 0.975, callback: progress)
        videoWriterInput.markAsFinished()

        for channel in passthroughChannels {
            channel.writerInput.markAsFinished()
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw TranscodeError.readerFailed(
                reader.error?.localizedDescription ?? "未知 AVAssetReader 错误"
            )
        }
        try checkCancellation(cancellationToken)

        reportStage("finish-writing", progress: 0.98, callback: progress)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription ?? "finishWriting 未完成"
            )
        }
        reportStage("writer-finished", progress: 0.985, callback: progress)

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
            videoEncodingPasses: 1,
            copiedNonVideoSamples: copiedNonVideoSamples
        )
    }

    private static func encodeMultiPass(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        nonVideoTracks: [AVAssetTrack],
        outputURL: URL,
        resolvedSettings: ResolvedTranscodeSettings,
        sourceColor: MediaColorSummary?,
        cancellationToken: EncodingCancellationToken,
        sourceDuration: Double,
        timeRange: CMTimeRange?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> RuntimeTranscodeResult {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw TranscodeError.unsupportedInput(error.localizedDescription)
        }
        writer.metadata = try await asset.load(.metadata)

        let dimensions = try await videoTrack.load(.naturalSize)
        let width = Int32(abs(dimensions.width.rounded()))
        let height = Int32(abs(dimensions.height.rounded()))
        guard width > 0, height > 0 else {
            throw TranscodeError.unsupportedInput("视频分辨率无效。")
        }

        var videoFormatHint: CMVideoFormatDescription?
        let formatHintStatus = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: resolvedSettings.codecType,
            width: width,
            height: height,
            extensions: nil,
            formatDescriptionOut: &videoFormatHint
        )
        guard formatHintStatus == noErr, let videoFormatHint else {
            throw TranscodeError.writerFailed(
                "无法创建压缩视频格式提示：\(formatHintStatus)"
            )
        }
        let videoWriterInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: videoFormatHint
        )
        guard writer.canAdd(videoWriterInput) else {
            throw TranscodeError.writerFailed("无法添加压缩视频轨道。")
        }
        writer.add(videoWriterInput)
        videoWriterInput.transform = try await videoTrack.load(.preferredTransform)
        videoWriterInput.metadata = try await videoTrack.load(.metadata)

        let passthroughReader: AVAssetReader?
        if nonVideoTracks.isEmpty {
            passthroughReader = nil
        } else {
            do {
                passthroughReader = try AVAssetReader(asset: asset)
            } catch {
                throw TranscodeError.unsupportedInput(error.localizedDescription)
            }
        }
        if let timeRange {
            passthroughReader?.timeRange = timeRange
        }
        var passthroughChannels: [PassthroughChannel] = []
        for track in nonVideoTracks {
            guard let passthroughReader else {
                throw TranscodeError.cannotPreserveTrack(
                    "\(track.mediaType.rawValue)#\(track.trackID)：无法创建读取器"
                )
            }
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
            guard passthroughReader.canAdd(readerOutput) else {
                throw TranscodeError.cannotPreserveTrack(
                    "\(track.mediaType.rawValue)#\(track.trackID)：无法读取压缩样本"
                )
            }
            let writerInput = AVAssetWriterInput(
                mediaType: track.mediaType,
                outputSettings: nil,
                sourceFormatHint: formatHint
            )
            guard writer.canAdd(writerInput) else {
                throw TranscodeError.cannotPreserveTrack(
                    "\(track.mediaType.rawValue)#\(track.trackID)：MOV 不接受原压缩格式"
                )
            }
            passthroughReader.add(readerOutput)
            writer.add(writerInput)
            writerInput.languageCode = try? await track.load(.languageCode)
            writerInput.extendedLanguageTag = try? await track.load(.extendedLanguageTag)
            writerInput.metadata = try await track.load(.metadata)
            passthroughChannels.append(
                PassthroughChannel(
                    readerOutput: readerOutput,
                    writerInput: writerInput
                )
            )
        }

        let sessionStartTime = try await sourceStartTime(
            videoTrack: videoTrack,
            nonVideoTracks: nonVideoTracks,
            timeRange: timeRange
        )
        let storageTimeRange = timeRange ?? CMTimeRange(
            start: sessionStartTime,
            duration: CMTime(
                seconds: sourceDuration,
                preferredTimescale: 60_000
            )
        )

        var multiPassStorage: VTMultiPassStorage?
        let storageStatus = VTMultiPassStorageCreate(
            allocator: kCFAllocatorDefault,
            fileURL: nil,
            timeRange: storageTimeRange,
            options: nil,
            multiPassStorageOut: &multiPassStorage
        )
        guard storageStatus == noErr, let multiPassStorage else {
            throw MultiPassUnavailable(
                propertyWrite: multiPassPropertyWrite(
                    function: "VTMultiPassStorageCreate",
                    status: storageStatus
                )
            )
        }
        defer {
            VTMultiPassStorageClose(multiPassStorage)
        }

        var frameSilo: VTFrameSilo?
        let siloStatus = VTFrameSiloCreate(
            allocator: kCFAllocatorDefault,
            fileURL: nil,
            timeRange: storageTimeRange,
            options: nil,
            frameSiloOut: &frameSilo
        )
        guard siloStatus == noErr, let frameSilo else {
            throw MultiPassUnavailable(
                propertyWrite: multiPassPropertyWrite(
                    function: "VTFrameSiloCreate",
                    status: siloStatus
                )
            )
        }

        let callbackContext = TranscodeCallbackContext()
        callbackContext.routeOutput(to: frameSilo)
        var compressionSession: VTCompressionSession?
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
            throw TranscodeError.compressionSessionFailed(sessionStatus)
        }
        defer {
            VTCompressionSessionInvalidate(compressionSession)
        }

        var propertyWrites = try configure(
            compressionSession,
            settings: resolvedSettings,
            sourceColor: sourceColor
        )
        let multiPassSetStatus = VTSessionSetProperty(
            compressionSession,
            key: kVTCompressionPropertyKey_MultiPassStorage,
            value: multiPassStorage
        )
        let multiPassWrite = PropertyWriteResult(
            key: "MultiPassStorage",
            requestedValue: .string("VTMultiPassStorage"),
            status: APICallResult(
                function: "VTSessionSetProperty(MultiPassStorage)",
                status: multiPassSetStatus
            )
        )
        propertyWrites.append(multiPassWrite)
        guard multiPassSetStatus == noErr else {
            throw MultiPassUnavailable(propertyWrite: multiPassWrite)
        }

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(
            compressionSession
        )
        guard prepareStatus == noErr else {
            throw TranscodeError.frameEncodingFailed(prepareStatus)
        }
        reportStage("multipass-prepared", progress: 0.03, callback: progress)

        let beginStatus = VTCompressionSessionBeginPass(
            compressionSession,
            flags: [],
            nil
        )
        guard beginStatus == noErr else {
            throw TranscodeError.frameEncodingFailed(beginStatus)
        }
        let firstPass = try encodeVideoPass(
            asset: asset,
            videoTrack: videoTrack,
            compressionSession: compressionSession,
            resolvedSettings: resolvedSettings,
            cancellationToken: cancellationToken,
            timeRange: timeRange,
            allowedTimeRanges: nil,
            progressStart: 0.03,
            progressEnd: 0.46,
            sourceDuration: sourceDuration,
            sessionStartTime: sessionStartTime,
            progress: progress
        )
        try completeCompressionPass(compressionSession)
        try callbackContext.throwIfFailed()

        var furtherPassesRequested = DarwinBoolean(false)
        let endFirstStatus = VTCompressionSessionEndPass(
            compressionSession,
            furtherPassesRequestedOut: &furtherPassesRequested,
            nil
        )
        guard endFirstStatus == noErr else {
            throw TranscodeError.frameEncodingFailed(endFirstStatus)
        }

        var passCount = 1
        if furtherPassesRequested.boolValue {
            var rangeCount: CMItemCount = 0
            var rangePointer: UnsafePointer<CMTimeRange>?
            let rangeStatus = VTCompressionSessionGetTimeRangesForNextPass(
                compressionSession,
                timeRangeCountOut: &rangeCount,
                timeRangeArrayOut: &rangePointer
            )
            guard rangeStatus == noErr,
                  rangeCount > 0,
                  let rangePointer
            else {
                throw TranscodeError.frameEncodingFailed(rangeStatus)
            }
            let rangeBuffer = UnsafeBufferPointer(
                start: rangePointer,
                count: Int(rangeCount)
            )
            let nextPassRanges = Array(rangeBuffer)
            let siloRangeStatus = VTFrameSiloSetTimeRangesForNextPass(
                frameSilo,
                timeRangeCount: rangeCount,
                timeRangeArray: rangePointer
            )
            guard siloRangeStatus == noErr else {
                throw TranscodeError.frameEncodingFailed(siloRangeStatus)
            }

            let beginFinalStatus = VTCompressionSessionBeginPass(
                compressionSession,
                flags: .beginFinalPass,
                nil
            )
            guard beginFinalStatus == noErr else {
                throw TranscodeError.frameEncodingFailed(beginFinalStatus)
            }
            _ = try encodeVideoPass(
                asset: asset,
                videoTrack: videoTrack,
                compressionSession: compressionSession,
                resolvedSettings: resolvedSettings,
                cancellationToken: cancellationToken,
                timeRange: timeRange,
                allowedTimeRanges: nextPassRanges,
                progressStart: 0.46,
                progressEnd: 0.89,
                sourceDuration: sourceDuration,
                sessionStartTime: sessionStartTime,
                progress: progress
            )
            try completeCompressionPass(compressionSession)
            try callbackContext.throwIfFailed()
            let endFinalStatus = VTCompressionSessionEndPass(
                compressionSession,
                furtherPassesRequestedOut: nil,
                nil
            )
            guard endFinalStatus == noErr else {
                throw TranscodeError.frameEncodingFailed(endFinalStatus)
            }
            passCount = 2
        }

        guard writer.startWriting() else {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription ?? "startWriting 返回 false"
            )
        }
        writer.startSession(atSourceTime: sessionStartTime)
        if let passthroughReader,
           !passthroughReader.startReading()
        {
            writer.cancelWriting()
            throw TranscodeError.readerFailed(
                passthroughReader.error?.localizedDescription
                    ?? "非视频轨道 startReading 返回 false"
            )
        }

        reportStage("multipass-write-final", progress: 0.90, callback: progress)
        let siloWriter = FrameSiloWriterContext(
            writer: writer,
            videoWriterInput: videoWriterInput,
            passthroughChannels: passthroughChannels,
            cancellationToken: cancellationToken
        )
        let siloReadStatus = VTFrameSiloCallBlockForEachSampleBuffer(
            frameSilo,
            in: storageTimeRange
        ) { sampleBuffer in
            siloWriter.receive(sampleBuffer)
        }
        if let error = siloWriter.error {
            writer.cancelWriting()
            throw error
        }
        guard siloReadStatus == noErr else {
            writer.cancelWriting()
            throw TranscodeError.writerFailed(
                "读取多遍最终码流失败（OSStatus \(siloReadStatus)）。"
            )
        }
        let remainingNonVideo = try drainRemainingPassthroughSamples(
            passthroughChannels,
            writer: writer,
            cancellationToken: cancellationToken
        )
        videoWriterInput.markAsFinished()
        for channel in passthroughChannels {
            channel.writerInput.markAsFinished()
        }

        if passthroughReader?.status == .failed {
            writer.cancelWriting()
            throw TranscodeError.readerFailed(
                passthroughReader?.error?.localizedDescription
                    ?? "未知 AVAssetReader 错误"
            )
        }
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
        guard firstPass.submittedFrames > 0,
              siloWriter.encodedFrames > 0
        else {
            throw TranscodeError.unsupportedInput("视频没有产生可封装的帧。")
        }
        guard siloWriter.encodedFrames == firstPass.submittedFrames else {
            throw TranscodeError.writerFailed(
                "首遍提交 \(firstPass.submittedFrames) 帧，但最终仅封装 "
                    + "\(siloWriter.encodedFrames) 帧。"
            )
        }

        return RuntimeTranscodeResult(
            propertyWrites: propertyWrites,
            hardwarePropertyQuery: APICallResult(
                function: "VTSessionCopyProperty(UsingHardwareAcceleratedVideoEncoder)",
                status: hardwareStatus
            ),
            usesHardwareEncoder: usesHardware,
            decodedVideoFrames: firstPass.decodedFrames,
            submittedVideoFrames: firstPass.submittedFrames,
            encodedVideoFrames: siloWriter.encodedFrames,
            droppedVideoFrames: callbackSnapshot.droppedFrames,
            videoEncodingPasses: passCount,
            copiedNonVideoSamples:
                siloWriter.copiedNonVideoSamples + remainingNonVideo
        )
    }

    private static func encodeVideoPass(
        asset: AVAsset,
        videoTrack: AVAssetTrack,
        compressionSession: VTCompressionSession,
        resolvedSettings: ResolvedTranscodeSettings,
        cancellationToken: EncodingCancellationToken,
        timeRange: CMTimeRange?,
        allowedTimeRanges: [CMTimeRange]?,
        progressStart: Double,
        progressEnd: Double,
        sourceDuration: Double,
        sessionStartTime: CMTime,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> VideoPassResult {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw TranscodeError.unsupportedInput(error.localizedDescription)
        }
        if let timeRange {
            reader.timeRange = timeRange
        }
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
            throw TranscodeError.unsupportedInput("无法为多遍编码创建解码输出。")
        }
        reader.add(videoOutput)
        guard reader.startReading() else {
            throw TranscodeError.readerFailed(
                reader.error?.localizedDescription ?? "startReading 返回 false"
            )
        }

        var decodedFrames = 0
        var submittedFrames = 0
        while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
            try checkCancellation(cancellationToken)
            decodedFrames += 1
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(
                sampleBuffer
            )
            if let allowedTimeRanges,
               !allowedTimeRanges.contains(where: {
                   CMTimeRangeContainsTime($0, time: presentationTime)
               })
            {
                continue
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                throw TranscodeError.unsupportedInput(
                    "解码输出没有 CVPixelBuffer。"
                )
            }
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
                reader.cancelReading()
                throw TranscodeError.frameEncodingFailed(encodeStatus)
            }
            submittedFrames += 1
            if sourceDuration > 0, presentationTime.isNumeric {
                let completed = max(
                    0,
                    CMTimeGetSeconds(
                        CMTimeSubtract(presentationTime, sessionStartTime)
                    )
                )
                let fraction = min(1, completed / sourceDuration)
                progress(
                    progressStart
                        + (progressEnd - progressStart) * fraction
                )
            }
        }
        if reader.status == .failed {
            throw TranscodeError.readerFailed(
                reader.error?.localizedDescription ?? "未知 AVAssetReader 错误"
            )
        }
        return VideoPassResult(
            decodedFrames: decodedFrames,
            submittedFrames: submittedFrames
        )
    }

    private static func completeCompressionPass(
        _ session: VTCompressionSession
    ) throws {
        let status = VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )
        guard status == noErr else {
            throw TranscodeError.frameEncodingFailed(status)
        }
    }

    private static func sourceStartTime(
        videoTrack: AVAssetTrack,
        nonVideoTracks: [AVAssetTrack],
        timeRange: CMTimeRange?
    ) async throws -> CMTime {
        if let timeRange {
            return timeRange.start
        }
        var earliestStart = CMTime.zero
        for track in [videoTrack] + nonVideoTracks {
            let start = try await track.load(.timeRange).start
            if start.isNumeric,
               (earliestStart == .zero
                   || CMTimeCompare(start, earliestStart) < 0)
            {
                earliestStart = start
            }
        }
        return earliestStart
    }

    private static func drainRemainingPassthroughSamples(
        _ channels: [PassthroughChannel],
        writer: AVAssetWriter,
        cancellationToken: EncodingCancellationToken
    ) throws -> Int {
        var copiedSamples = 0
        var lastProgressAt = ProcessInfo.processInfo.systemUptime
        while channels.contains(where: { !$0.reachedEnd }) {
            var madeProgress = false
            for channel in channels {
                if try channel.appendOneIfReady(
                    through: .positiveInfinity,
                    writer: writer
                ) {
                    copiedSamples += 1
                    madeProgress = true
                }
            }
            if madeProgress {
                lastProgressAt = ProcessInfo.processInfo.systemUptime
                continue
            }
            try checkCancellation(cancellationToken)
            try checkWriterState(writer)
            try checkPipelineStall(since: lastProgressAt)
            Thread.sleep(forTimeInterval: 0.002)
        }
        return copiedSamples
    }

    private static func multiPassPropertyWrite(
        function: String,
        status: OSStatus
    ) -> PropertyWriteResult {
        PropertyWriteResult(
            key: "MultiPassStorage",
            requestedValue: .string("VTMultiPassStorage"),
            status: APICallResult(function: function, status: status)
        )
    }

    private struct PipelineDrainResult {
        let copiedNonVideoSamples: Int
        let madeProgress: Bool
    }

    private static func drainReadySamples(
        callbackContext: TranscodeCallbackContext,
        videoWriterInput: AVAssetWriterInput,
        passthroughChannels: [PassthroughChannel],
        through limit: CMTime,
        writer: AVAssetWriter,
        cancellationToken: EncodingCancellationToken
    ) throws -> PipelineDrainResult {
        var copiedNonVideoSamples = 0
        var madeProgress = false

        while true {
            try checkCancellation(cancellationToken)
            try callbackContext.throwIfFailed()
            try checkWriterState(writer)

            var roundMadeProgress = false
            if try callbackContext.appendOneIfReady(
                into: videoWriterInput,
                writer: writer
            ) {
                roundMadeProgress = true
            }
            for channel in passthroughChannels {
                if try channel.appendOneIfReady(
                    through: limit,
                    writer: writer
                ) {
                    copiedNonVideoSamples += 1
                    roundMadeProgress = true
                }
            }

            guard roundMadeProgress else {
                break
            }
            madeProgress = true
        }

        return PipelineDrainResult(
            copiedNonVideoSamples: copiedNonVideoSamples,
            madeProgress: madeProgress
        )
    }

    private static func drainUntilVideoQueueHasCapacity(
        callbackContext: TranscodeCallbackContext,
        videoWriterInput: AVAssetWriterInput,
        passthroughChannels: [PassthroughChannel],
        through limit: CMTime,
        writer: AVAssetWriter,
        cancellationToken: EncodingCancellationToken
    ) throws -> Int {
        let maximumPendingVideoSamples = 24
        var copiedNonVideoSamples = 0
        var lastProgressAt = ProcessInfo.processInfo.systemUptime

        while callbackContext.pendingSampleCount > maximumPendingVideoSamples {
            let result = try drainReadySamples(
                callbackContext: callbackContext,
                videoWriterInput: videoWriterInput,
                passthroughChannels: passthroughChannels,
                through: limit,
                writer: writer,
                cancellationToken: cancellationToken
            )
            copiedNonVideoSamples += result.copiedNonVideoSamples
            if result.madeProgress {
                lastProgressAt = ProcessInfo.processInfo.systemUptime
                continue
            }
            try checkCancellation(cancellationToken)
            try callbackContext.throwIfFailed()
            try checkWriterState(writer)
            try checkPipelineStall(since: lastProgressAt)
            Thread.sleep(forTimeInterval: 0.002)
        }

        return copiedNonVideoSamples
    }

    private static func drainAllRemainingSamples(
        callbackContext: TranscodeCallbackContext,
        videoWriterInput: AVAssetWriterInput,
        passthroughChannels: [PassthroughChannel],
        writer: AVAssetWriter,
        cancellationToken: EncodingCancellationToken
    ) throws -> Int {
        var copiedNonVideoSamples = 0
        var lastProgressAt = ProcessInfo.processInfo.systemUptime

        while callbackContext.pendingSampleCount > 0
            || passthroughChannels.contains(where: { !$0.reachedEnd })
        {
            let result = try drainReadySamples(
                callbackContext: callbackContext,
                videoWriterInput: videoWriterInput,
                passthroughChannels: passthroughChannels,
                through: .positiveInfinity,
                writer: writer,
                cancellationToken: cancellationToken
            )
            copiedNonVideoSamples += result.copiedNonVideoSamples
            if result.madeProgress {
                lastProgressAt = ProcessInfo.processInfo.systemUptime
                continue
            }
            try checkCancellation(cancellationToken)
            try callbackContext.throwIfFailed()
            try checkWriterState(writer)
            try checkPipelineStall(since: lastProgressAt)
            Thread.sleep(forTimeInterval: 0.002)
        }

        return copiedNonVideoSamples
    }

    private static func checkWriterState(_ writer: AVAssetWriter) throws {
        if writer.status == .failed || writer.status == .cancelled {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription ?? "AVAssetWriter 已停止"
            )
        }
    }

    private static func checkPipelineStall(since lastProgressAt: TimeInterval) throws {
        if ProcessInfo.processInfo.systemUptime - lastProgressAt > 30 {
            throw TranscodeError.writerFailed(
                "所有轨道连续 30 秒无法写入，任务已停止以避免永久挂起。"
            )
        }
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

    private static func appendOptionalProperty(
        to writes: inout [PropertyWriteResult],
        session: VTCompressionSession,
        key: CFString,
        name: String,
        value: CFTypeRef
    ) {
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
        let nonVideoInput = trackInventory(input.nonVideoTracks)
        let nonVideoOutput = trackInventory(output.nonVideoTracks)
        let inputMetadata = Set(input.metadata)
        let outputMetadata = Set(output.metadata)
        let missingMetadata = inputMetadata.subtracting(outputMetadata)
        let missingVideoMetadata = Set(inputVideo.metadata)
            .subtracting(Set(outputVideo.metadata))

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
                name: "视频帧率与轨道时间",
                passed: abs(
                    inputVideo.nominalFrameRate - outputVideo.nominalFrameRate
                ) <= 0.01
                    && abs(
                        inputVideo.timeRangeStartSeconds
                            - outputVideo.timeRangeStartSeconds
                    ) <= frameTolerance
                    && abs(
                        inputVideo.timeRangeDurationSeconds
                            - outputVideo.timeRangeDurationSeconds
                    ) <= frameTolerance,
                inputValue: trackTiming(inputVideo),
                outputValue: trackTiming(outputVideo),
                detail: "重新读取视频轨道的帧率、起点和轨道时长。"
            ),
            PreservationCheck(
                name: "色彩与 HDR 描述",
                passed: colorPreserved(
                    input: inputVideo.color,
                    output: outputVideo.color
                ),
                inputValue: String(describing: inputVideo.color),
                outputValue: String(describing: outputVideo.color),
                detail: "色域、传递函数、矩阵、位深和 HDR 静态元数据逐项一致。"
            ),
            PreservationCheck(
                name: "视频轨道元数据",
                passed: missingVideoMetadata.isEmpty,
                inputValue: "\(inputVideo.metadata.count) 项",
                outputValue: "\(outputVideo.metadata.count) 项",
                detail: missingVideoMetadata.isEmpty
                    ? "输入视频轨道元数据均可在输出中重新读取。"
                    : "缺少 \(missingVideoMetadata.count) 项视频轨道元数据。"
            ),
            PreservationCheck(
                name: "非视频轨道无损直通",
                passed: nonVideoTracksPreserved(
                    input: input.nonVideoTracks,
                    output: output.nonVideoTracks,
                    tolerance: frameTolerance
                ),
                inputValue: nonVideoInput.description,
                outputValue: nonVideoOutput.description,
                detail: "压缩格式、时间范围、时间刻度、语言和轨道元数据逐项复核。"
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
            PreservationCheck(
                name: "文件修改时间",
                passed: input.modificationDate == nil
                    || input.modificationDate == output.modificationDate,
                inputValue: input.modificationDate ?? "unknown",
                outputValue: output.modificationDate ?? "unknown",
                detail: "输出文件尽力继承源文件修改时间。"
            ),
        ]
    }

    private static func trackInventory(
        _ tracks: [MediaTrackSummary]
    ) -> [String: Int] {
        Dictionary(
            grouping: tracks,
            by: { "\($0.mediaType)|\($0.codecFourCC)" }
        )
        .mapValues(\.count)
    }

    private static func nonVideoTracksPreserved(
        input: [MediaTrackSummary],
        output: [MediaTrackSummary],
        tolerance: Double
    ) -> Bool {
        guard input.count == output.count else {
            return false
        }

        var unmatched = output
        for inputTrack in input {
            guard let match = unmatched.firstIndex(where: { outputTrack in
                inputTrack.mediaType == outputTrack.mediaType
                    && inputTrack.codecType == outputTrack.codecType
                    && inputTrack.languageCode == outputTrack.languageCode
                    && inputTrack.extendedLanguageTag
                        == outputTrack.extendedLanguageTag
                    && inputTrack.naturalTimeScale
                        == outputTrack.naturalTimeScale
                    && abs(
                        inputTrack.timeRangeStartSeconds
                            - outputTrack.timeRangeStartSeconds
                    ) <= tolerance
                    && abs(
                        inputTrack.timeRangeDurationSeconds
                            - outputTrack.timeRangeDurationSeconds
                    ) <= tolerance
                    && Set(inputTrack.metadata)
                        .isSubset(of: Set(outputTrack.metadata))
            }) else {
                return false
            }
            unmatched.remove(at: match)
        }
        return unmatched.isEmpty
    }

    private static func trackTiming(_ track: MediaTrackSummary) -> String {
        String(
            format: "%.3f fps · %.6f…%.6f s",
            track.nominalFrameRate,
            track.timeRangeStartSeconds,
            track.timeRangeStartSeconds + track.timeRangeDurationSeconds
        )
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

    private static func colorPreserved(
        input: MediaColorSummary?,
        output: MediaColorSummary?
    ) -> Bool {
        guard let input else {
            return true
        }
        guard let output else {
            return false
        }
        return optionalFieldPreserved(
            input.colorPrimaries,
            output.colorPrimaries
        )
            && optionalFieldPreserved(
                input.transferFunction,
                output.transferFunction
            )
            && optionalFieldPreserved(input.yCbCrMatrix, output.yCbCrMatrix)
            && optionalFieldPreserved(
                input.bitsPerComponent,
                output.bitsPerComponent
            )
            && optionalFieldPreserved(
                input.masteringDisplayColorVolume,
                output.masteringDisplayColorVolume
            )
            && optionalFieldPreserved(
                input.contentLightLevelInfo,
                output.contentLightLevelInfo
            )
    }

    private static func optionalFieldPreserved<Value: Equatable>(
        _ input: Value?,
        _ output: Value?
    ) -> Bool {
        guard let input else {
            return true
        }
        return input == output
    }

    private static func makeOutputURL(
        sourceFileName: String,
        codecType: CMVideoCodecType
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoToolboxStudio", isDirectory: true)
            .appendingPathComponent("Transcoded", isDirectory: true)
        let safeFileName = URL(fileURLWithPath: sourceFileName).lastPathComponent
        let baseName = URL(fileURLWithPath: safeFileName)
            .deletingPathExtension()
            .lastPathComponent
        let codec = codecType == kCMVideoCodecType_HEVC ? "HEVC" : "H264"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let fileName = "\(baseName)-\(codec)-\(formatter.string(from: Date())).mov"
        return directory.appendingPathComponent(fileName)
    }

    private static func makeEstimateOutputURL(
        sourceFileName: String,
        codecType: CMVideoCodecType
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoToolboxStudio", isDirectory: true)
            .appendingPathComponent("Estimates", isDirectory: true)
        let baseName = URL(fileURLWithPath: sourceFileName)
            .deletingPathExtension()
            .lastPathComponent
        let codec = codecType == kCMVideoCodecType_HEVC ? "HEVC" : "H264"
        return directory.appendingPathComponent(
            "\(baseName)-\(codec)-\(UUID().uuidString).mov"
        )
    }

    private static func applySourceDates(
        from source: MediaAssetSummary,
        to output: URL
    ) throws {
        let formatter = ISO8601DateFormatter()
        var outputAttributes: [FileAttributeKey: Any] = [:]
        if let creationDate = source.creationDate.flatMap({
            formatter.date(from: $0)
        }) {
            outputAttributes[.creationDate] = creationDate
        }
        if let modificationDate = source.modificationDate.flatMap({
            formatter.date(from: $0)
        }) {
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

    private static func reportStage(
        _ stage: String,
        progress: Double,
        callback: @escaping @Sendable (Double) -> Void
    ) {
        print("VT_TRANSCODE_STAGE=\(stage)")
        callback(progress)
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

private struct MultiPassUnavailable: Error {
    let propertyWrite: PropertyWriteResult
}

private struct VideoPassResult {
    let decodedFrames: Int
    let submittedFrames: Int
}

private struct RuntimeTranscodeResult {
    var propertyWrites: [PropertyWriteResult]
    let hardwarePropertyQuery: APICallResult
    let usesHardwareEncoder: Bool
    let decodedVideoFrames: Int
    let submittedVideoFrames: Int
    let encodedVideoFrames: Int
    let droppedVideoFrames: Int
    let videoEncodingPasses: Int
    let copiedNonVideoSamples: Int
}

private final class FrameSiloWriterContext: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoWriterInput: AVAssetWriterInput
    private let passthroughChannels: [PassthroughChannel]
    private let cancellationToken: EncodingCancellationToken
    private let lock = NSLock()
    private var storedError: TranscodeError?
    private var storedEncodedFrames = 0
    private var storedCopiedNonVideoSamples = 0

    init(
        writer: AVAssetWriter,
        videoWriterInput: AVAssetWriterInput,
        passthroughChannels: [PassthroughChannel],
        cancellationToken: EncodingCancellationToken
    ) {
        self.writer = writer
        self.videoWriterInput = videoWriterInput
        self.passthroughChannels = passthroughChannels
        self.cancellationToken = cancellationToken
    }

    var error: TranscodeError? {
        lock.withLock { storedError }
    }

    var encodedFrames: Int {
        lock.withLock { storedEncodedFrames }
    }

    var copiedNonVideoSamples: Int {
        lock.withLock { storedCopiedNonVideoSamples }
    }

    func receive(_ sampleBuffer: CMSampleBuffer) -> OSStatus {
        do {
            let copiedSamples = try append(sampleBuffer)
            lock.withLock {
                storedEncodedFrames += 1
                storedCopiedNonVideoSamples += copiedSamples
            }
            return noErr
        } catch let error as TranscodeError {
            lock.withLock {
                if storedError == nil {
                    storedError = error
                }
            }
            return -1
        } catch {
            lock.withLock {
                if storedError == nil {
                    storedError = .writerFailed(error.localizedDescription)
                }
            }
            return -1
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) throws -> Int {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(
            sampleBuffer
        )
        var copiedSamples = 0
        var lastProgressAt = ProcessInfo.processInfo.systemUptime

        while true {
            if cancellationToken.isCancelled || Task.isCancelled {
                throw TranscodeError.cancelled
            }
            if writer.status == .failed || writer.status == .cancelled {
                throw TranscodeError.writerFailed(
                    writer.error?.localizedDescription ?? "AVAssetWriter 已停止"
                )
            }

            var madeProgress = false
            for channel in passthroughChannels {
                while try channel.appendOneIfReady(
                    through: presentationTime,
                    writer: writer
                ) {
                    copiedSamples += 1
                    madeProgress = true
                }
            }
            if videoWriterInput.isReadyForMoreMediaData {
                guard videoWriterInput.append(sampleBuffer) else {
                    throw TranscodeError.writerFailed(
                        writer.error?.localizedDescription
                            ?? "多遍视频轨道 append 返回 false"
                    )
                }
                return copiedSamples
            }
            if madeProgress {
                lastProgressAt = ProcessInfo.processInfo.systemUptime
                continue
            }
            if ProcessInfo.processInfo.systemUptime - lastProgressAt > 30 {
                throw TranscodeError.writerFailed(
                    "多遍最终码流连续 30 秒无法写入。"
                )
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
    }
}

private final class PassthroughChannel {
    let readerOutput: AVAssetReaderTrackOutput
    let writerInput: AVAssetWriterInput
    private var pendingSample: CMSampleBuffer?
    private(set) var reachedEnd = false

    init(
        readerOutput: AVAssetReaderTrackOutput,
        writerInput: AVAssetWriterInput
    ) {
        self.readerOutput = readerOutput
        self.writerInput = writerInput
    }

    func appendOneIfReady(
        through limit: CMTime,
        writer: AVAssetWriter
    ) throws -> Bool {
        guard !reachedEnd else {
            return false
        }
        if pendingSample == nil {
            pendingSample = readerOutput.copyNextSampleBuffer()
            if pendingSample == nil {
                reachedEnd = true
                return false
            }
        }
        guard let sample = pendingSample else {
            return false
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        if limit != .positiveInfinity,
           presentationTime.isNumeric,
           CMTimeCompare(presentationTime, limit) > 0
        {
            return false
        }
        guard writerInput.isReadyForMoreMediaData else {
            if writer.status == .failed || writer.status == .cancelled {
                throw TranscodeError.writerFailed(
                    writer.error?.localizedDescription ?? "AVAssetWriter 已停止"
                )
            }
            return false
        }
        guard writerInput.append(sample) else {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription
                    ?? "非视频轨道 append 返回 false"
            )
        }
        pendingSample = nil
        return true
    }
}

private struct TranscodeCallbackSnapshot {
    let encodedFrames: Int
    let droppedFrames: Int
}

private final class TranscodeCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingSamples: [CMSampleBuffer] = []
    private var nextPendingSampleIndex = 0
    private var encodedFrames = 0
    private var droppedFrames = 0
    private var failure: TranscodeError?
    private var frameSilo: VTFrameSilo?

    var pendingSampleCount: Int {
        lock.withLock {
            pendingSamples.count - nextPendingSampleIndex
        }
    }

    func routeOutput(to frameSilo: VTFrameSilo) {
        lock.withLock {
            self.frameSilo = frameSilo
        }
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
                return
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
            if let frameSilo {
                let status = VTFrameSiloAddSampleBuffer(
                    frameSilo,
                    sampleBuffer: sampleBuffer
                )
                if status != noErr {
                    failure = .writerFailed(
                        "多遍码流暂存失败（OSStatus \(status)）。"
                    )
                }
                return
            }
            pendingSamples.append(sampleBuffer)
        }
    }

    func appendOneIfReady(
        into writerInput: AVAssetWriterInput,
        writer: AVAssetWriter
    ) throws -> Bool {
        try throwIfFailed()
        guard writerInput.isReadyForMoreMediaData else {
            if writer.status == .failed || writer.status == .cancelled {
                throw TranscodeError.writerFailed(
                    writer.error?.localizedDescription ?? "AVAssetWriter 已停止"
                )
            }
            return false
        }
        let sample: CMSampleBuffer? = lock.withLock {
            guard nextPendingSampleIndex < pendingSamples.count else {
                return nil
            }
            let sample = pendingSamples[nextPendingSampleIndex]
            nextPendingSampleIndex += 1
            if nextPendingSampleIndex >= 64,
               nextPendingSampleIndex * 2 >= pendingSamples.count
            {
                pendingSamples.removeFirst(nextPendingSampleIndex)
                nextPendingSampleIndex = 0
            }
            return sample
        }
        guard let sample else {
            return false
        }
        guard writerInput.append(sample) else {
            throw TranscodeError.writerFailed(
                writer.error?.localizedDescription
                    ?? "视频轨道 append 返回 false"
            )
        }
        lock.withLock {
            encodedFrames += 1
        }
        return true
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
