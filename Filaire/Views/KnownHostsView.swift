import SwiftUI

public struct KnownHostsView: View {
    @State private var entries: [KnownHostEntry] = []

    public init() {}

    public var body: some View {
        List {
            if entries.isEmpty {
                Section {
                    Text("No known hosts stored yet. Servers will be automatically recorded on first connection (TOFU).")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            } else {
                Section(
                    header: Text("Trusted Host Keys"),
                    footer: Text("Host keys protect against Man-in-the-Middle attacks. If a server is reinstalled, delete its entry here so you can accept the new key.")
                ) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(entry.hostname):\(entry.port)")
                                    .font(.headline)
                                Spacer()
                                Text(entry.keyType)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(uiColor: SolarizedDarkTheme.base02))
                                    .foregroundStyle(Color(uiColor: SolarizedDarkTheme.cyan))
                                    .clipShape(Capsule())
                            }

                            Text(entry.fingerprintSHA256)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Text("First seen: \(entry.firstSeen.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: deleteEntries)
                }
            }
        }
        .navigationTitle("Known Hosts")
        .onAppear {
            loadEntries()
        }
    }

    private func loadEntries() {
        entries = KnownHostsStore.shared.getAllEntries()
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            let entry = entries[index]
            KnownHostsStore.shared.removeEntry(hostname: entry.hostname, port: entry.port)
        }
        entries.remove(atOffsets: offsets)
    }
}
