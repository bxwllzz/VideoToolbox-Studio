import Foundation
import Testing
@testable import VideoToolboxStudio

struct CapabilityReportTests {
    @Test
    func JSON值保留字典数组和布尔类型() throws {
        let value = JSONValue(
            foundationValue: [
                "硬件": true,
                "档位": ["Main", "High"],
                "码率": 12_000_000,
            ] as NSDictionary
        )

        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["硬件"] as? Bool == true)
        #expect(object["码率"] as? Int == 12_000_000)
        #expect(object["档位"] as? [String] == ["Main", "High"])
    }

    @Test
    func 证据摘要不会把缺失等级伪装为连续通过() {
        let configuration = EncoderProbeConfiguration(
            label: "HEVC 4K",
            codecType: 0,
            codecFourCC: "hvc1",
            width: 3_840,
            height: 2_160,
            requiresHardwareEncoder: true
        )
        let success = APICallResult(function: "测试", status: 0)
        let probe = EncoderConfigurationProbe(
            configuration: configuration,
            preflight: success,
            selectedEncoderID: "测试编码器",
            preflightSupportedProperties: nil,
            sessionCreation: success,
            sessionPropertyQuery: success,
            sessionSupportedProperties: nil,
            hardwarePropertyQuery: success,
            usesHardwareEncoder: true,
            evidence: [.preflight, .sessionCreated, .sessionPropertiesRead, .hardwareRuntimeProperty]
        )

        #expect(probe.evidenceSummary == "E1 · E2 · E3 · E5")
    }
}
