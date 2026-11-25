import SongforMeKit
import SwiftUI

/// 添加插件：粘贴链接，或者选电脑上的文件
struct AddSourceForm: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var working = false
    @State private var problem: String?

    private var empty: Bool { link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加插件").font(.title3.bold())
            TextField("", text: $link, prompt: Text("粘贴插件链接"))
                .textFieldStyle(.roundedBorder)
                .disabled(working)
                .onSubmit(add)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).lineLimit(3).fixedSize(horizontal: false, vertical: true).transition(.opacity)
            }
            HStack(spacing: 10) {
                Button("选择文件…") {
                    dismiss()
                    app.chooseSource()
                }
                .disabled(working)
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("添加", action: add).keyboardShortcut(.defaultAction).disabled(empty || working)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 380)
        .animation(.snappy(duration: 0.2), value: problem)
    }

    private func add() {
        guard !empty, !working else { return }
        guard let url = ScriptDownload.address(of: link) else { return problem = "要用 https 开头的链接" }
        working = true
        problem = nil
        Task {
            do {
                let text = try await ScriptDownload.text(of: url)
                dismiss()
                await app.addSource(script: text, from: url.host())
            } catch {
                problem = error.localizedDescription
                working = false
            }
        }
    }
}
