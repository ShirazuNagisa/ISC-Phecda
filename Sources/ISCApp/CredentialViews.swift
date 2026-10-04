import SwiftUI
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

    private var provider: Provider? {
        model.providers.first { $0.name == providerName }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("添加 DNS 凭据", "Add a DNS credential")).font(.headline).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker(tr("服务商", "Provider"), selection: $providerName) {
                        Text(tr("请选择", "Select")).tag(String?.none)
                        ForEach(model.providers) { item in
                            Text(item.displayName).tag(String?.some(item.name))
                        }
                    }
                    .onChange(of: providerName) { _, _ in values = [:] }

                    TextField(tr("名称（自己认得就行）", "Label (anything you recognise)"), text: $label)
                        .textFieldStyle(.roundedBorder)

                    if let provider {
                        ForEach(provider.credentialFields) { field in
                            fieldInput(field)
                        }
                        capabilitiesHint(provider)
                    }

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

    @ViewBuilder private func fieldInput(_ field: ProviderField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(field.label).font(.callout)
                if field.required {
                    Text("*").font(.caption).foregroundStyle(.red)
                }
            }
            if field.secret {
                SecureField(field.placeholder ?? "", text: binding(field.key))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(field.placeholder ?? "", text: binding(field.key))
                    .textFieldStyle(.roundedBorder)
            }
            if let help = field.help, !help.isEmpty {
                Text(help).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func capabilitiesHint(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !provider.capabilities.dns01 {
                Label(tr("该服务商不支持 DNS-01，无法用它签发证书。",
                         "This provider does not support DNS-01, so it cannot be used to issue certificates."),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !provider.capabilities.canManageRecords {
                Label(tr("该服务商不支持列区域或列记录，因此不能在这里管理解析条目。",
                         "This provider cannot list zones or records, so records cannot be managed here."),
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }

    private var canSave: Bool {
        guard let provider, !label.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return provider.credentialFields
            .filter(\.required)
            .allSatisfy { !(values[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func save() async {
        guard let provider else { return }
        busy = true
        failure = nil
        do {
            // 只提交填过的字段：空字符串会被内核当成"显式清空"，
            // 而用户只是没填可选项。
            let filled = values.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
            let input = CredentialInput(provider: provider.name, label: label, fields: filled)
            _ = try await model.kernel.createCredential(input)
            await onSaved()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
        busy = false
    }
}
