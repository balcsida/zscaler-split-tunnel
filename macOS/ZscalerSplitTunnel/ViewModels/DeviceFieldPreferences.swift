import Foundation
import Observation

@Observable
@MainActor
final class DeviceFieldPreferences {
    private static let key = "menuBarDeviceFields"

    var enabledFields: Set<DeviceField> {
        didSet { save() }
    }

    init() {
        if let stored = UserDefaults.standard.stringArray(forKey: Self.key) {
            enabledFields = Set(stored.compactMap { DeviceField(rawValue: $0) })
        } else {
            enabledFields = DeviceField.defaultEnabled
        }
    }

    func isEnabled(_ field: DeviceField) -> Bool {
        enabledFields.contains(field)
    }

    func toggle(_ field: DeviceField) {
        if enabledFields.contains(field) {
            enabledFields.remove(field)
        } else {
            enabledFields.insert(field)
        }
    }

    private func save() {
        UserDefaults.standard.set(
            enabledFields.map(\.rawValue),
            forKey: Self.key
        )
    }
}
