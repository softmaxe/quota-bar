import Foundation

enum CoreResources {
    /// Packaged apps keep SwiftPM resources in Contents/Resources. Resolve them there first so a
    /// distributed app never relies on SwiftPM's absolute development-build fallback.
    static var bundle: Bundle {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("QuotaBar_QuotaBarCore.bundle")
        return bundled.flatMap(Bundle.init(url:)) ?? Bundle.module
    }
}
