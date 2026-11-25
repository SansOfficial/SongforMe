import SongforMeKit
import SwiftUI

/// 填一个音源的服务器、账号
struct SourceForm: View {
    let source: ScriptSource
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var checking = false
    @State private var problem: String?

    private var filled: Bool { source.fields.allSatisfy { $0.optional || !(values[$0.key] ?? "").isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(source.info.name).font(.title3.bold())
            ForEach(source.fields) { f in
                let value = Binding(get: { values[f.key] ?? "" }, set: { values[f.key] = $0 })
                VStack(alignment: .leading, spacing: 5) {
                    Text(f.title + (f.optional ? "（可不填）" : "")).font(.callout).foregroundStyle(.secondary)
                    if f.kind == .secret {
                        SecureField("", text: value)
                    } else {
                        TextField("", text: value, prompt: f.kind == .server ? Text("https://") : nil)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(checking)
            .onSubmit(save)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).lineLimit(3).fixedSize(horizontal: false, vertical: true).transition(.opacity)
            }
            HStack(spacing: 10) {
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("好", action: save).keyboardShortcut(.defaultAction).disabled(!filled || checking)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 340)
        .animation(.snappy(duration: 0.2), value: problem)
        .onAppear { values = source.settings }
    }

    private func save() {
        guard filled, !checking else { return }
        checking = true
        problem = nil
        Task {
            problem = await app.saveSettings(source, values)
            checking = false
        }
    }
}
