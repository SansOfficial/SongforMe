import SongforMeKit
import SwiftUI

/// 设置：外观、歌词、更新，推荐算法和口味种子歌单，音源和账号。⌘, 或者左下角菜单打开
struct SettingsPage: View {
    let tab: SettingsTab
    @Environment(AppModel.self) private var app

    var body: some View {
        PageHead(title: "设置") {}
        SettingsTabs(tab: tab)
            .padding(.bottom, 26)
        Group {
            switch tab {
            case .general: GeneralSettings()
            case .reco: RecoSettingsView()
            case .sources: SourceSettings()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
        .animation(.smooth(duration: 0.2), value: tab)
    }
}

extension SettingsTab {
    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .reco: "sparkles"
        case .sources: "person.crop.circle.fill"
        }
    }
}

/// 顶上的分类：图标加文字，选中的那项变成主题色、底下一道滑过去的横线；整排压在一条通栏的细线上，和下面的内容分开
private struct SettingsTabs: View {
    let tab: SettingsTab
    @Environment(AppModel.self) private var app
    @Namespace private var space
    @State private var hovering: SettingsTab?

    var body: some View {
        HStack(spacing: 28) {
            ForEach(SettingsTab.allCases, id: \.self) { t in
                let on = t == tab
                Button { app.go(.settings(t)) } label: {
                    VStack(spacing: 10) {
                        Label(t.title, systemImage: t.icon)
                            .font(.system(size: 15, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(hovering == t ? .primary : .secondary))
                        ZStack {
                            Capsule().fill(.clear).frame(height: 3)
                            if on {
                                Capsule().fill(Theme.accent).frame(height: 3).matchedGeometryEffect(id: "line", in: space)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 ? t : (hovering == t ? nil : hovering) }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .background(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.1)).frame(height: 1) }
        .animation(.spring(duration: 0.32, bounce: 0.15), value: tab)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @Environment(DesktopLyrics.self) private var desktop
    @State private var appearance = Appearance.current

    var body: some View {
        @Bindable var desktop = desktop
        let notch = NotchLyrics.shared
        let updater = Updater.shared
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard("外观") {
                SettingRow("主题", icon: "circle.lefthalf.filled", color: .indigo) {
                    Picker("主题", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    .onChange(of: appearance) { Appearance.current = appearance }
                }
            }
            SettingsCard("歌词") {
                SettingRow("桌面歌词", "浮在所有窗口上面，可以拖到任何地方", icon: "text.quote", color: .blue) {
                    Switch(isOn: Binding { desktop.visible } set: { _ in desktop.toggle() })
                }
                RowDivider()
                SettingRow("锁定桌面歌词", "锁定后点不到它，不挡下面的窗口", icon: "lock.fill", color: .orange) {
                    Switch(isOn: $desktop.locked)
                }
                .disabled(!desktop.visible)
                RowDivider()
                SettingRow("桌面歌词字号", icon: "textformat.size", color: .teal) {
                    HStack(spacing: 10) {
                        Slider(value: $desktop.fontSize, in: DesktopLyrics.sizes, step: 2).frame(width: 200).tint(Theme.accent)
                        Text("\(Int(desktop.fontSize))").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                    }
                }
                .disabled(!desktop.visible)
                RowDivider()
                SettingRow("刘海歌词", "放歌时在屏幕顶上的刘海下面显示正在唱的这句，指针停在上面展开成小播放器；没有刘海的屏幕挂在菜单栏中间", icon: "laptopcomputer", color: .pink) {
                    Switch(isOn: Binding { notch.visible } set: { _ in notch.toggle() })
                }
            }
            SettingsCard("更新") {
                SettingRow("当前版本", updater.supported ? nil : "这个版本带本机音源，不自动更新", icon: "info", color: .gray) {
                    Text(updater.current).monospacedDigit().foregroundStyle(.secondary)
                }
                if updater.supported {
                    RowDivider()
                    SettingRow("自动检查新版本", "打开时和之后每天问一次 GitHub，只发这一个请求，不带任何个人信息", icon: "clock.arrow.circlepath", color: .green) {
                        Switch(isOn: Binding { updater.autoCheck } set: { updater.autoCheck = $0 })
                    }
                    RowDivider()
                    if let release = updater.available {
                        SettingRow("有新版本 \(release.version)", icon: "arrow.down", color: .red) {
                            Button(updater.status ?? "更新") { Task { await updater.install() } }.disabled(updater.status != nil)
                        }
                    } else {
                        SettingRow("检查更新", icon: "arrow.down", color: .blue) {
                            Button(updater.checking ? "正在检查…" : "现在检查") { Task { await updater.checkNow() } }.disabled(updater.checking)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 推荐

private struct RecoSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button("按现在的设置换一批", systemImage: "arrow.clockwise") {
                    Task {
                        await app.generate()
                        app.go(.reco)
                    }
                }
                .secondaryButton()
                .disabled(app.likedMids.isEmpty || app.busy != nil)
                Button("扩充候选池", systemImage: "scope") { Task { await app.expand() } }
                    .secondaryButton()
                    .disabled(app.likedMids.isEmpty || app.busy != nil)
            }
            .padding(.bottom, 26)

            SettingsCard("推荐算法") {
                Knob(title: "歌手", left: "只要熟悉的歌手", right: "尽量是没听过的歌手", key: \.exploration, icon: "person.2.fill", color: .indigo)
                RowDivider()
                Knob(title: "热度", left: "大众热门", right: "冷门小众", key: \.obscurity, icon: "flame.fill", color: .orange)
                RowDivider()
                Knob(title: "新旧", left: "不在乎发行时间", right: "偏向新歌", key: \.freshness, icon: "calendar", color: .teal)
                RowDivider()
                Knob(title: "贴合口味", left: "语种 / 流派 / 年代随便", right: "严格贴合我平时听的", key: \.tasteMatch, icon: "scope", color: .pink)
                RowDivider()
                Knob(title: "熟歌回放", left: "全是新歌", right: "一半是很久没听的喜欢的歌", key: \.familiarRatio, max: 0.5, unit: "%", icon: "arrow.counterclockwise", color: .green)
            }
            SettingsCard("每一批") {
                NumberRow(title: "每批数量", key: \.batchSize, range: 5...100, icon: "square.stack.fill", color: .blue)
                RowDivider()
                NumberRow(title: "同一歌手最多", key: \.maxPerArtist, range: 1...10, icon: "person.fill", color: .purple)
                RowDivider()
                NumberRow(title: "几天内不重复推荐", key: \.repeatCooldownDays, range: 0...365, icon: "repeat", color: .orange)
            }
            SettingsCard("语种") {
                SettingRow("只推荐这些语种", "点一下选上或去掉", icon: "globe", color: .cyan) { EmptyView() }
                FlowLayout(spacing: 8) {
                    ForEach(Languages.all, id: \.code) { code, name in
                        Toggle(name, isOn: language(code)).toggleStyle(.button).tint(Theme.accent)
                    }
                }
                .padding(.leading, RowIcon.inset)
                .padding(.bottom, 14)
            }
            SeedSettings()
        }
    }

    private func language(_ code: Int) -> Binding<Bool> {
        Binding(get: { app.settings.languages?.contains(code) ?? true }, set: { on in
            let all = Languages.all.map(\.code)
            var now = Set(app.settings.languages ?? all)
            if on { now.insert(code) } else { now.remove(code) }
            app.update { $0.languages = now.count == all.count || now.isEmpty ? nil : now.sorted() }
        })
    }
}

/// 导入公开歌单当口味种子，查看、移除已导入的
private struct SeedSettings: View {
    @Environment(AppModel.self) private var app
    @State private var link = ""

    var body: some View {
        let list = app.playlists.filter { $0.kind == .imported }
        SettingsCard("口味种子歌单", note: "导入的歌会计入你的口味。") {
            HStack(spacing: 12) {
                RowIcon(icon: "music.note.list", color: .red)
                TextField("粘贴歌单链接或歌单号", text: $link).textFieldStyle(.roundedBorder).onSubmit(submit)
                Button("导入", action: submit).disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || app.busy != nil)
            }
            .padding(.vertical, 12)
            ForEach(list) { p in
                RowDivider()
                SettingRow(p.title, "\(p.songCount) 首", icon: "music.note", color: .red.opacity(0.7)) {
                    HStack(spacing: 2) {
                        IconButton(icon: "arrow.up.right", label: "打开「\(p.title)」", size: 11) { app.go(.playlist(p.id)) }
                        IconButton(icon: "xmark", label: "移除种子歌单「\(p.title)」", size: 11) { Task { await app.removePlaylist(p.id) } }
                    }
                }
            }
        }
    }

    private func submit() {
        let text = link
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task {
            await app.importSeed(text)
            link = ""
        }
    }
}

// MARK: - 音源与账号

private struct SourceSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let accounts = app.hub.all.filter(\.hasAccount)
        VStack(alignment: .leading, spacing: 0) {
            SettingsCard("音源", note: "插件是别人写的程序，只添加你信任的。") {
                ForEach(Array(app.hub.all.enumerated()), id: \.element.info.id) { i, source in
                    if i > 0 { RowDivider() }
                    let plugin = source is ScriptSource
                    SettingRow(source.info.name, plugin ? "插件" : "自带", icon: plugin ? "puzzlepiece.extension.fill" : "music.note", color: plugin ? .orange : .green) {
                        if let script = source as? ScriptSource {
                            HStack(spacing: 2) {
                                if !script.fields.isEmpty {
                                    IconButton(icon: "gearshape", label: "设置\(source.info.spaced)", size: 12) { app.settingUp = SourceSetup(source: script) }
                                }
                                IconButton(icon: "xmark", label: "移除\(source.info.spaced)", size: 12) { app.askRemove(script) }
                            }
                        }
                    }
                }
                if !app.hub.all.isEmpty { RowDivider() }
                SettingRow("添加插件", "从文件或链接添加一个音源插件", icon: "plus", color: .gray) {
                    Button("添加…") { app.adding = true }
                }
            }
            if !accounts.isEmpty {
                SettingsCard("账号") {
                    ForEach(Array(accounts.enumerated()), id: \.element.info.id) { i, source in
                        if i > 0 { RowDivider() }
                        let on = app.loggedIn(source)
                        SettingRow(source.info.name, on ? "已登录：\(app.name(of: source))" : "未登录", icon: "person.crop.circle.fill", color: on ? .blue : .gray) {
                            Button(on ? "退出登录" : "登录") { Task { on ? await app.logout(source) : await app.login(source) } }
                        }
                    }
                    if app.loggedIn {
                        RowDivider()
                        SettingRow("同步曲库", "从账号里重新取喜欢的歌和歌单", icon: "arrow.triangle.2.circlepath", color: .green) {
                            Button("现在同步") { Task { await app.sync() } }.disabled(app.busy != nil)
                        }
                    }
                    if app.canSyncLikes {
                        RowDivider()
                        SettingRow("喜欢和歌单同步到账号", "在这里点喜欢、改歌单，账号里也跟着改", icon: "heart.fill", color: .red) {
                            Switch(isOn: Binding { app.syncLikes } set: { app.setSyncLikes($0) })
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 部件

/// 一组设置：标题加一块浅色底
private struct SettingsCard<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: Content

    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .background(.primary.opacity(0.035), in: .rect(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)) }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 4) }
        }
        .padding(.bottom, 24)
    }
}

/// 行前面的彩色小方块图标，像系统设置那样
private struct RowIcon: View {
    let icon: String
    let color: Color
    static let size: CGFloat = 28
    static let inset: CGFloat = size + 12

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: Self.size, height: Self.size)
            .background(color.gradient, in: .rect(cornerRadius: 7))
    }
}

/// 行之间的分隔线，从文字那里开始，不压着图标
private struct RowDivider: View {
    var body: some View { Divider().padding(.leading, RowIcon.inset) }
}

/// 一行：左边图标和说明，右边开关或按钮
private struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    let icon: String
    let color: Color
    @ViewBuilder var control: Control

    init(_ title: String, _ detail: String? = nil, icon: String, color: Color, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.color = color
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(icon: icon, color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            control
        }
        .frame(minHeight: 32)
        .padding(.vertical, 10)
    }
}

private struct Switch: View {
    let isOn: Binding<Bool>
    var body: some View {
        Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Theme.accent)
    }
}

private struct Knob: View {
    let title: String
    let left: String
    let right: String
    let key: WritableKeyPath<RecoSettings, Double>
    var max = 1.0
    var unit = ""
    let icon: String
    let color: Color
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowIcon(icon: icon, color: color)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int((app.settings[keyPath: key] * 100).rounded()))\(unit)").monospacedDigit().foregroundStyle(color)
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(height: RowIcon.size)
                Slider(value: Binding(get: { app.settings[keyPath: key] }, set: { v in app.update { $0[keyPath: key] = (v * 20 / max).rounded() / 20 * max } }), in: 0...max)
                    .tint(color)
                    .accessibilityLabel(title)
                HStack {
                    Text(left)
                    Spacer()
                    Text(right)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
    }
}

private struct NumberRow: View {
    let title: String
    let key: WritableKeyPath<RecoSettings, Int>
    let range: ClosedRange<Int>
    let icon: String
    let color: Color
    @Environment(AppModel.self) private var app

    var body: some View {
        let value = Binding(get: { app.settings[keyPath: key] }, set: { v in app.update { $0[keyPath: key] = min(range.upperBound, max(range.lowerBound, v)) } })
        SettingRow(title, icon: icon, color: color) {
            HStack(spacing: 4) {
                TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 64)
                Stepper(title, value: value, in: range).labelsHidden()
            }
        }
    }
}

/// 一行放不下就换行
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > maxWidth {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
