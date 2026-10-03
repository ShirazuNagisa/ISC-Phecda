import SwiftUI
import Foundation
import ISCCore
import ISCSupervisor

struct RuntimeManifestSheet: View {
    let model: AppModel
    @Binding var manifest: RuntimeManifest?
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var sha256 = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            manifestContent
            Divider()
            refreshFields
            errorView
            actions
        }
        .padding(22)
        .frame(width: 620, height: 500)
        .task { load() }
    }

    private var header: some View {
        HStack {
            Text(tr("运行时清单", "Runtime manifest")).font(.title2.bold())
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var manifestContent: some View {
        if let current = manifest {
            Text(tr("已加载 schema \(current.schemaVersion)", "Loaded schema \(current.schemaVersion)"))
                .foregroundStyle(.secondary)
            List(current.artifacts) { artifact in
                VStack(alignment: .leading) {
                    Text("\(artifact.runtime) \(artifact.version)").font(.headline)
                    Text("\(artifact.archiveName) · \(artifact.sha256)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(minHeight: 180)
        } else {
            ContentUnavailableView(
                tr("尚未加载运行时清单", "No runtime manifest loaded"),
                systemImage: "shippingbox"
            )
        }
    }

    private var refreshFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("刷新需要 HTTPS 地址和 manifest SHA-256。", "Refresh requires an HTTPS URL and manifest SHA-256."))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("https://…/runtime-manifest.json", text: $url)
            TextField(tr("manifest SHA-256", "Manifest SHA-256"), text: $sha256)
        }
    }

    @ViewBuilder private var errorView: some View {
        if let message { Text(message).foregroundStyle(.red) }
    }

    private var actions: some View {
        HStack {
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button(tr("读取当前清单", "Load current")) { load() }
            Button(tr("校验并刷新", "Verify and refresh")) { refresh() }
                .buttonStyle(.borderedProminent)
                .disabled(busy || url.isEmpty || sha256.count != 64)
        }
    }

    private func load() {
        guard let client = model.supervisorClient else {
            message = tr("独立 Supervisor 未运行。", "Independent Supervisor is unavailable.")
            return
        }
        busy = true
        Task {
            do { manifest = try await client.manifest(); message = nil }
            catch let caught { message = caught.localizedDescription }
            busy = false
        }
    }

    private func refresh() {
        guard let client = model.supervisorClient, let manifestURL = URL(string: url) else {
            message = tr("manifest URL 无效。", "Invalid manifest URL.")
            return
        }
        busy = true
        Task {
            do { manifest = try await client.manifest(url: manifestURL, sha256: sha256); message = nil }
            catch let caught { message = caught.localizedDescription }
            busy = false
        }
    }
}
