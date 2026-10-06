import SwiftUI
import AppKit
import ISCCore

/// 凭据管理：列出、校验、删除，以及新建。
///
/// 表单字段由服务商自己声明（`/v1/providers` 的 `credential_fields`），
/// 因此增加一个服务商不需要改这里 —— 硬编码各家的 API Key / Secret / Token
/// 迟早会与内核那边的定义对不上。
struct CredentialListView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingAdd = false
    @State private var verifying: String?
    @State private var results: [String: String] = [:]
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("DNS 凭据", "DNS credentials")).font(.headline)
                    Text(tr("解析域名、签发证书都要用到它。", "Used for DNS records and certificate issuance."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(tr("添加", "Add")) { showingAdd = true }
                    .buttonStyle(.glassProminent)
            }
            .padding(20)

            Divider()

            if model.credentials.isEmpty {
                EmptyHint(symbol: "key",
                          title: tr("还没有凭据", "No credentials yet"),
                          message: tr("添加一个 DNS 服务商的凭据之后，才能管理解析并签发证书。",
                                      "Add a DNS provider credential to manage records and issue certificates."),
                          action: (tr("添加凭据", "Add a credential"), { showingAdd = true }))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.credentials) { credential in
                            row(credential)
                        }
                    }
                    .padding(16)
                }
            }

            if let failure {
                Divider()
                Text(failure).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
            }

            Divider()
            HStack {
                Spacer()
                Button(tr("完成", "Done")) { dismiss() }
            }
            .padding(16)
        }
        .frame(width: 560, height: 460)
        .sheet(isPresented: $showingAdd) {
            CredentialFormView(model: model) { await model.refreshAll() }
        }
    }

    private func row(_ credential: CredentialInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(credential)).foregroundStyle(tint(credential))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(credential.label).font(.callout.weight(.medium))
                    Text(credential.provider).font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }
                Text(caption(credential)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = results[credential.id] {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if verifying == credential.id {
                ProgressView().controlSize(.small)
            } else {
                Button(tr("校验", "Verify")) { Task { await verify(credential) } }
                    .buttonStyle(.glass).controlSize(.small)
                Button(role: .destructive) {
                    Task { await remove(credential) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: .rect(cornerRadius: 10))
    }

    private func symbol(_ credential: CredentialInfo) -> String {
        switch credential.verifyState {
        case "ok": "checkmark.seal.fill"
        case "failed": "exclamationmark.triangle.fill"
        default: "key"
        }
    }

    private func tint(_ credential: CredentialInfo) -> Color {
        switch credential.verifyState {
        case "ok": .green
        case "failed": .orange
        default: .secondary
        }
    }

    private func caption(_ credential: CredentialInfo) -> String {
        if let error = credential.lastVerifyError, !error.isEmpty { return error }
        guard let at = credential.lastVerifiedAt else { return tr("尚未校验", "Not verified yet") }
        let stamp = at.formatted(date: .abbreviated, time: .shortened)
        return credential.lastVerifyOk == true
            ? tr("校验通过 · \(stamp)", "Verified · \(stamp)")
            : tr("校验失败 · \(stamp)", "Verification failed · \(stamp)")
    }

    private func verify(_ credential: CredentialInfo) async {
        verifying = credential.id
        failure = nil
        do {
            let result = try await model.kernel.verifyCredential(id: credential.id)
            results[credential.id] = result.message
            await model.refreshAll()
        } catch {
            failure = error.localizedDescription
        }
        verifying = nil
    }

    private func remove(_ credential: CredentialInfo) async {
        failure = nil
        do {
            try await model.kernel.deleteCredential(id: credential.id)
            results[credential.id] = nil
            await model.refreshAll()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// 新建凭据的表单。
struct CredentialFormView: View {
    @Bindable var model: AppModel
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var providerName: String?
    @State private var label = ""
    @State private var values: [String: String] = [:]
    @State private var busy = false
    @State private var failure: String?
    /// 本次表单里已经替用户打开过配置页的服务商。
    ///
    /// 用它去重：用户在下拉里来回比较几家时，不该每选一次就弹一个标签页。
    @State private var openedCredentialPages: Set<String> = []

    private var provider: Provider? {
        model.providers.first { $0.name == providerName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("添加 DNS 凭据", "Add a DNS credential")).font(.headline).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CredentialFieldsView(model: model,
                                         providerName: $providerName,
                                         label: $label,
                                         values: $values,
                                         openedCredentialPages: $openedCredentialPages)

                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(tr("取消", "Cancel")) { dismiss() }
                Button(tr("添加", "Add")) { Task { await save() } }
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave || busy)
            }
            .padding(16)
        }
        .frame(width: 520, height: 520)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private var canSave: Bool {
        CredentialDraft.isValid(provider: provider, label: label, values: values)
    }

    private func save() async {
        guard let provider else { return }
        busy = true
        failure = nil
        do {
            _ = try await model.kernel.createCredential(
                CredentialDraft.input(provider: provider, label: label, values: values))
            await onSaved()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}
