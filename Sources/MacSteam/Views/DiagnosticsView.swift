// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Diagnostics screen showing recent log entries.
struct DiagnosticsView: View {
    @ObservedObject var manager: GameManager
    @Environment(\.dismiss) private var dismiss
    @State private var diagnostics: [DiagnosticEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.title3)
                .fontWeight(.semibold)

            if diagnostics.isEmpty {
                Text("No diagnostics entries yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(diagnostics.reversed()) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(formattedTimestamp(entry.timestamp))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .monospaced()
                                Text(entry.message)
                                    .font(.caption)
                                    .foregroundStyle(entry.type == .error ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                            .padding(4)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button("Copy All") {
                    let text = diagnostics.map {
                        "[\(formattedTimestamp($0.timestamp))] \($0.message)"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .controlSize(.small)

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.escape)
            }
        }
        .padding(20)
        .frame(width: 520, height: 400)
        .onAppear {
            diagnostics = manager.lastDiagnostics
        }
    }

    private func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
