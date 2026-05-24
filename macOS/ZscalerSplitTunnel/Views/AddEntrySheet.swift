import SwiftUI

struct AddEntrySheet: View {
    let configType: ConfigType
    let onAdd: (String) -> Void

    @State private var entryText: String = ""
    @State private var validationError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Add \(configType == .routes ? "Zscaler Route" : "Direct Override") Entry")
                .font(.headline)

            TextField("e.g. 10.0.0.0/8, example.com, https://...", text: $entryText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { validate() }

            if let error = validationError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Text("Supported formats: IP address, CIDR notation, domain name, wildcard (*.example.com), or URL")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { validate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(entryText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
    }

    private func validate() {
        let trimmed = entryText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            validationError = "Entry cannot be empty"
            return
        }

        guard ConfigEntry.parse(trimmed) != nil else {
            validationError = "Invalid entry format"
            return
        }

        validationError = nil
        onAdd(trimmed)
        dismiss()
    }
}
