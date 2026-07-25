import Darwin
import Foundation

enum DeviceInfo {
    static var identifier: String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else {
            return "unknown"
        }

        let capacity = MemoryLayout.size(ofValue: systemInfo.machine)
            / MemoryLayout<CChar>.stride

        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { characterPointer in
                String(cString: characterPointer)
            }
        }
    }
}
