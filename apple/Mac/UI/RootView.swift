import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var searching = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar().navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            ZStack(alignment: .bottom) {
                PageView()
                    .animation(.smooth(duration: 0.25), value: app.page.identity)
                    .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 92) }
                VStack(spacing: 10) {
                    Notices()
                    PlayerBar()
                }
            }
            .background(Theme.sheet.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("返回上一页", systemImage: "chevron.left") { app.back() }.disabled(app.history.isEmpty)
                }
            }
            .navigationTitle("")
            .searchable(text: $app.query, isPresented: $searching, placement: .toolbar, prompt: "搜索歌曲、歌手、专辑")
            .onSubmit(of: .search) { app.search(app.query) }
        }
        .tint(Theme.accent)
        .frame(minWidth: 860, minHeight: 560)
        .sheet(isPresented: $app.adding) { AddSourceForm() }
        .sheet(item: $app.settingUp) { SourceForm(source: $0.source) }
        .task { await app.start() }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in searching = true }
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("focusSearch")
}

/// 播放条上方的进度和提示
private struct Notices: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: 8) {
            if let toast = app.toast {
                Text(toast.text)
                    .foregroundStyle(toast.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(in: .capsule)
                    .id(toast.id)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            if let busy = app.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).lineLimit(1).contentTransition(.opacity)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(in: .capsule)
                .transition(.opacity.combined(with: .offset(y: 10)))
            }
        }
        .padding(.horizontal, 30)
        .animation(.spring(duration: 0.35), value: app.toast)
        .animation(.spring(duration: 0.35), value: app.busy == nil)
    }
}
