import Foundation
import Testing
@testable import VideoToolboxStudio

struct SustainedEncodingReportTests {
    @Test
    func 百分位统计采用最近秩且不伪造空值() {
        #expect(SustainedEncodingProbe.percentile95([]) == nil)
        #expect(SustainedEncodingProbe.percentile95([3]) == 3)
        #expect(SustainedEncodingProbe.percentile95(Array(1...20).map(Double.init)) == 19)
    }

    @Test
    func 验收目标按配置要求的证据判断() {
        let result = makeResult(
            requiredEvidence: .sustainedThroughput,
            evidence: [.sessionCreated, .bitstreamProduced, .hardwareRuntimeProperty]
        )

        #expect(!result.meetsAcceptanceTarget)
        #expect(result.evidenceSummary == "E2 · E4 · E5")
    }

    @Test
    func 报告JSON保留E4到E6和吞吐指标() throws {
        let result = makeResult(
            requiredEvidence: .sustainedThroughput,
            evidence: [
                .sessionCreated,
                .bitstreamProduced,
                .hardwareRuntimeProperty,
                .sustainedThroughput,
            ]
        )
        let report = SustainedEncodingReport(
            schemaVersion: "1.0",
            generatedAt: "2026-07-26T00:00:00Z",
            app: AppIdentity(version: "1.2.0", build: "1", commitSHA: "abc"),
            device: DeviceIdentity(
                identifier: "iPhone18,1",
                model: "iPhone",
                systemName: "iOS",
                systemVersion: "26.2"
            ),
            durationSeconds: 2,
            targetFramesPerSecond: 30,
            thermalStateBefore: "nominal",
            thermalStateAfter: "nominal",
            cancelled: false,
            configurations: [result]
        )

        let data = try JSONEncoder().encode(report)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let configurations = try #require(json["configurations"] as? [[String: Any]])
        let encodedResult = try #require(configurations.first)

        #expect(encodedResult["evidence"] as? [String] == ["E2", "E4", "E5", "E6"])
        #expect(report.passedConfigurationCount == 1)
    }

    private func makeResult(
        requiredEvidence: EvidenceLevel,
        evidence: [EvidenceLevel]
    ) -> SustainedEncodingResult {
        let configuration = SustainedEncodingConfiguration(
            label: "H.264 1080p30",
            codecType: 0,
            codecFourCC: "avc1",
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            durationSeconds: 2,
            averageBitRate: 8_000_000,
            requiredEvidence: requiredEvidence
        )
        let success = APICallResult(function: "测试", status: 0)
        return SustainedEncodingResult(
            configuration: configuration,
            sessionCreation: success,
            propertyWrites: [],
            prepare: success,
            pixelBufferPoolAvailable: true,
            completeFrames: success,
            hardwarePropertyQuery: success,
            usesHardwareEncoder: true,
            metrics: SustainedEncodingMetrics(
                requestedFrames: 60,
                submittedFrames: 60,
                callbackFrames: 60,
                outputSampleBuffers: 60,
                failedFrames: 0,
                droppedFrames: 0,
                keyFrames: 2,
                reorderedFrames: 0,
                totalEncodedBytes: 1_000,
                wallClockSeconds: 1,
                throughputFramesPerSecond: 60,
                firstCallbackLatencyMilliseconds: 1,
                meanCallbackLatencyMilliseconds: 2,
                p95CallbackLatencyMilliseconds: 3,
                maximumInFlightFrames: 10,
                measuredBitRate: 8_000
            ),
            outputFormat: nil,
            callbackStatuses: [],
            evidence: evidence,
            cancelled: false
        )
    }
}
