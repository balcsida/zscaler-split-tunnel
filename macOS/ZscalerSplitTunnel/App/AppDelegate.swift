import Cocoa
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    func installHelper() -> Bool {
        do {
            try SMAppService.daemon(plistName: "\(AppConstants.helperBundleID).plist").register()
            return true
        } catch {
            return false
        }
    }
}
