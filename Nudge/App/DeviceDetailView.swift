import SwiftUI

/// One saved device: its name, its keys and the tasks saved for it. Labels can be corrected
/// here, since a key is saved the way it was first read.
struct DeviceDetailView: View {
    let deviceID: UUID
    @ObservedObject private var store = DeviceStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var device: SavedDevice? { store.device(deviceID) }

    var body: some View {
        Form {
            if let device {
                Section("Name") {
                    TextField("Name", text: binding(\.name, in: device))
                        .accessibilityLabel("Device name")
                }

                Section {
                    if device.routines.isEmpty {
                        Text("None yet. Do a task on this device with demo-safe mode off, and it is kept here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(device.routines) { routine in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.phrase)
                            Text(routine.steps.joined(separator: ", then "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete { offsets in
                        var changed = device
                        changed.routines.remove(atOffsets: offsets)
                        store.update(changed)
                    }
                } header: {
                    Text("Saved tasks")
                } footer: {
                    Text("Say the same words again and Nudge goes straight to these keys.")
                }

                Section {
                    ForEach(device.keys) { key in
                        TextField("Label", text: keyBinding(key, in: device))
                            .accessibilityLabel("Key label")
                    }
                } header: {
                    Text("Keys")
                } footer: {
                    Text("Correct any label that was read wrongly. This is what Nudge will call the key.")
                }

                Section {
                    Button("Delete this device", role: .destructive) { confirmDelete = true }
                }
            } else {
                Text("This device has been deleted.")
            }
        }
        .navigationTitle(device?.name ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this device and its saved tasks?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.remove(deviceID)
                dismiss()
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func binding(_ path: WritableKeyPath<SavedDevice, String>, in device: SavedDevice) -> Binding<String> {
        Binding(get: { device[keyPath: path] }, set: { value in
            var changed = device
            changed[keyPath: path] = value
            store.update(changed)
        })
    }

    /// Editing a key's label also renames it in the saved tasks that press it.
    private func keyBinding(_ key: SavedKey, in device: SavedDevice) -> Binding<String> {
        Binding(get: { key.label }, set: { value in
            var changed = device
            guard let index = changed.keys.firstIndex(where: { $0.id == key.id }) else { return }
            let old = changed.keys[index].label
            changed.keys[index].label = value
            for r in changed.routines.indices {
                changed.routines[r].steps = changed.routines[r].steps.map { DeviceStore.key($0) == DeviceStore.key(old) ? value : $0 }
            }
            store.update(changed)
        })
    }
}
