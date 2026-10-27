import SwiftUI
import AppKit

@main
struct DawnTranslateApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("DawnTranslate", id: "main") {
            ContentView(model: model, microphone: model.microphone, meeting: model.meeting, output: model.output)
                .frame(minWidth: 980, minHeight: 700)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }
        .defaultSize(width: 1160, height: 790)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .pasteboard) {
                Button("剪切") { NSApplication.shared.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x", modifiers: .command)
                Button("复制") { NSApplication.shared.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("粘贴") { model.pasteFromClipboard() }.keyboardShortcut("v", modifiers: .command)
                Button("粘贴（Ctrl+V）") { model.pasteFromClipboard() }.keyboardShortcut("v", modifiers: .control)
            }
            CommandMenu("沟通") {
                Button("粘贴文字 / 截图") { model.pasteFromClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("打开会议翻译") { model.workspace = .meeting }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("暂停会议 / 停止语音") { model.conversation.stop(); model.stopSpeech() }.keyboardShortcut(".", modifiers: .command)
                Button("AI 与设备设置") { model.workspace = .settings }.keyboardShortcut(",")
            }
        }
        MenuBarExtra("DawnTranslate", systemImage: "character.bubble") {
            QuickTranslationMenu(model: model)
        }.menuBarExtraStyle(.menu)
    }
}

struct QuickTranslationMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    private func show(_ page: Workspace) {
        model.workspace = page
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some View {
        Button(model.quickAccessAvailable ? "打开 DawnTranslate    ⌃⌥D" : "打开 DawnTranslate") { show(.translate) }
        Button(model.quickAccessAvailable ? "粘贴文字 / 截图…    ⌃⌥V" : "粘贴文字 / 截图…") { show(.translate); model.importTranslation(paste: true) }
            .disabled(model.busy)
        Button("导入内容…") { show(.translate); model.importTranslation(paste: false) }
            .disabled(model.busy)
        Divider()
        Button("邮件回复") { show(.email) }
        Button("会议翻译 · Teams / 飞书") { show(.meeting) }
        Button("暂停会议翻译") { model.conversation.stop() }
        if model.output.isSpeaking || model.speechPending { Button("停止语音") { model.conversation.stop(); model.stopSpeech() } }
        Divider()
        Button("设置") { show(.settings) }
        Button("退出 DawnTranslate") { model.shutdown(); NSApplication.shared.terminate(nil) }
    }
}

let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(red: 0.42, green: 0.78, blue: 0.69, alpha: 1)
        : NSColor(red: 0.12, green: 0.40, blue: 0.36, alpha: 1)
})

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var microphone: SpeechInput
    @ObservedObject var meeting: SpeechInput
    @ObservedObject var output: SpeechOutput
    @State private var showReplyMeaning = false
    private enum MailTab: Hashable { case source, translation }
    private enum MailField: Hashable { case context, intent, reply }
    private enum MailAction { case translate, reply }
    @State private var mailTab: MailTab = .source
    @State private var mailAction: MailAction?
    @State private var focusReplyAfterImport = false
    @State private var copiedReply = false
    @FocusState private var mailFocus: MailField?
    @FocusState private var translationFocus: Bool
    @FocusState private var sidebarFocus: Workspace?
    @State private var mailDropTarget = false
    @State private var translationDropTarget = false
    @State private var showHistory = false
    @State private var showConnection = false
    @State private var showVoiceHelp = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text(model.workspace.rawValue).font(.system(size: 20, weight: .semibold))
                    if model.requiresKeyAuthorization {
                        Button("连接 AI", systemImage: "lock") { model.workspace = .settings }.controlSize(.small)
                    }
                    Spacer()
                    if let notice = model.notice {
                        Label(notice, systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Button("取消") { model.cancelWork() }
                    }
                }.padding(.horizontal, 24).padding(.vertical, 19)
                if let error = model.error { banner(error, failure: true) }
                Group {
                    switch model.workspace {
                    case .translate: translateView
                    case .email: emailView
                    case .meeting: MeetingConversationView(model: model, conversation: model.conversation)
                    case .speak: speakView
                    case .settings: settingsView
                    }
                }.padding(.horizontal, 24).padding(.bottom, 20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.tint(accent)
            .onChange(of: model.workspace) { _, workspace in
                // Mouse navigation must not leave keyboard focus on the previous page.
                if sidebarFocus != nil { sidebarFocus = workspace }
            }
            .task(id: model.notice) {
                guard let notice = model.notice else { return }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                if model.notice == notice { model.notice = nil }
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 28, height: 28)
                Text("DawnTranslate").font(.system(size: 14, weight: .semibold))
            }.padding(.top, 10).padding(.bottom, 8)
            VStack(spacing: 6) {
                ForEach(Workspace.allCases.filter { $0 != .settings && $0 != .speak }) { item in nav(item) }
            }
            Spacer()
            ConversationActivityView(conversation: model.conversation)
            if meeting.isRunning { Label("正在监听会议", systemImage: "record.circle").font(.system(size: 12)).foregroundStyle(accent) }
            if microphone.isRunning { Label("正在录音 · 中英自动识别", systemImage: "mic.fill").font(.system(size: 12)).foregroundStyle(.red) }
            if output.isSpeaking || model.speechPending || (microphone.isTranscribing && !microphone.isRunning) { Button("停止语音", systemImage: "stop.fill") { model.stopSpeech() } }
            Divider()
            nav(.settings)
        }.padding(14).frame(width: 168).frame(maxHeight: .infinity).background(.regularMaterial)
    }
    private func nav(_ item: Workspace) -> some View {
        Button { sidebarFocus = item; model.workspace = item } label: {
            Label(item.rawValue, systemImage: item.icon)
                .font(.system(size: 13, weight: model.workspace == item ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                .foregroundStyle(model.workspace == item ? accent : Color.primary)
                .background(model.workspace == item ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .focused($sidebarFocus, equals: item)
            .focusEffectDisabled()
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(sidebarFocus == item ? accent.opacity(0.55) : .clear, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityAddTraits(model.workspace == item ? .isSelected : [])
    }
    private func banner(_ text: String, failure: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: failure ? "exclamationmark.circle" : "checkmark.circle")
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { if failure { model.error = nil } else { model.notice = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示")
        }.font(.system(size: 12)).foregroundStyle(failure ? Color.red : accent)
            .padding(12).background(failure ? Color.red.opacity(0.06) : accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24).padding(.bottom, 14)
    }

    private var translateView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Label(model.detectedDirection.label, systemImage: "character.bubble")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("历史", systemImage: "clock.arrow.circlepath") { showHistory = true }
                    .help("本次使用的最近 30 条，退出后清除")
                Button("交换", systemImage: "arrow.left.arrow.right") { model.swapTranslation() }
                    .disabled(model.busy || model.translation.isEmpty)
                Spacer(minLength: 0)
            }.controlSize(.small)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("原文").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Button("导入内容", systemImage: "square.and.arrow.down") { model.importTranslation(paste: false) }
                            .help("导入图片、PDF、Word（.docx、.doc），也可直接拖入文件")
                        Button("清空") { model.cancelWork(); model.source = ""; model.translation = ""; model.resultDirection = nil }
                            .disabled(model.source.isEmpty && model.translation.isEmpty)
                        Spacer(minLength: 0)
                    }.controlSize(.small).disabled(model.busy).frame(height: 26)
                    editor("原文", text: $model.source, placeholder: "输入中英文，或拖入图片、PDF、Word…", acceptsImages: true, showsTitle: false)
                        .focused($translationFocus)
                    HStack(spacing: 12) {
                        Button("翻译", systemImage: "arrow.right") { model.translate() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                            .disabled(model.busy || model.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Enter 翻译 · Shift+Enter 换行")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity)
                result((model.resultDirection ?? model.detectedDirection).resultTitle, text: model.translation, placeholder: "译文会显示在这里。")
            }
            Text(model.quickAccessAvailable ? "⌃⌥D 随时打开   ·   ⌃⌥V 粘贴文字或截图" : "快捷键被占用，请从菜单栏打开；⌘⇧V 可在此页粘贴。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }.sheet(isPresented: $showHistory) { historyView }
            .onChange(of: translationFocus) { _, focused in model.translationInputFocused = focused }
            .onDisappear { model.translationInputFocused = false }
    }

    private var historyView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("最近翻译").font(.headline)
                Spacer()
                Button("清除记录") { model.translationHistory.clear() }.disabled(model.translationHistory.records.isEmpty)
                Button("完成") { showHistory = false }.keyboardShortcut(.cancelAction)
            }
            Text("仅保留本次使用的最近 30 条，不写入磁盘。点击记录可恢复原文和译文。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if model.translationHistory.records.isEmpty {
                ContentUnavailableView("还没有翻译记录", systemImage: "clock", description: Text("完成文字翻译后，结果会出现在这里。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.translationHistory.records) { record in
                    Button {
                        model.restoreTranslation(record); showHistory = false
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.direction.resultTitle).font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Text(record.date, style: .time).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Text(record.source).lineLimit(2)
                            Text(record.result).foregroundStyle(accent).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }.listStyle(.plain)
            }
        }.padding(24).frame(width: 600, height: 470)
    }

    private var emailView: some View {
        GeometryReader { geometry in
            let readingWidth = min(420, max(280, geometry.size.width * 0.43))
            HStack(alignment: .top, spacing: 24) {
                mailSourcePanel.frame(width: readingWidth)
                ScrollView {
                    mailReplyPanel(width: geometry.size.width - readingWidth - 24)
                        .padding(.bottom, 16)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: mailTab) { _, tab in
            guard tab == .translation, model.contextMeaning.isEmpty,
                  !model.emailContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !model.requiresKeyAuthorization || TranslationDirection.detect(model.emailContext) == .undetermined {
                translateMailContext()
            }
        }
        .onChange(of: model.emailContext) { _, _ in mailTab = .source }
        .onChange(of: model.emailReply) { _, _ in copiedReply = false }
        .onChange(of: model.busy) { _, busy in
            if !busy {
                if focusReplyAfterImport && model.error == nil && !model.emailContext.isEmpty { mailFocus = .intent }
                focusReplyAfterImport = false
                mailAction = nil
            }
        }
        .task(id: copiedReply) {
            guard copiedReply else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copiedReply = false
        }
    }

    private var mailSourcePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("来信").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("清空", systemImage: "trash") {
                    model.emailContext = ""; mailTab = .source; mailFocus = .context
                }.disabled(model.busy || model.emailContext.isEmpty)
            }.controlSize(.small)
            Picker("来信显示", selection: $mailTab) {
                Text("原文").tag(MailTab.source)
                Text(model.emailDraft.contextDirection == .undetermined ? "译文" : model.emailDraft.contextDirection.resultTitle).tag(MailTab.translation)
            }.pickerStyle(.segmented).labelsHidden().disabled(model.busy)
            if !model.emailContext.isEmpty {
                Text(model.emailDraft.contextDirection.label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if mailTab == .source {
                ZStack(alignment: .topLeading) {
                    if model.emailContext.isEmpty {
                        Text("拖入截图，或按 ⌘V / Ctrl+V 粘贴\n也可以直接输入中英文内容。")
                            .font(.system(size: 14)).lineSpacing(5).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                    }
                    TextEditor(text: $model.emailContext).font(.system(size: 14)).lineSpacing(3)
                        .scrollContentBackground(.hidden).focused($mailFocus, equals: .context)
                        .disabled(model.busy).accessibilityLabel("来信原文")
                        .onDrop(of: ImageImport.dropTypes, isTargeted: $mailDropTarget) { acceptMailDrop($0) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mailChineseReference.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.padding(16).frame(maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(mailDropTarget ? accent : Color.primary.opacity(0.06), lineWidth: mailDropTarget ? 2 : 1))
            .onDrop(of: ImageImport.dropTypes, isTargeted: $mailDropTarget) { acceptMailDrop($0) }
    }

    @ViewBuilder
    private var mailChineseReference: some View {
        if !model.contextMeaning.isEmpty {
            ScrollView {
                Text(model.contextMeaning).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        } else if model.busy && mailAction == .translate {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在翻译来信…") }
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 12)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.emailContext.isEmpty ? "添加来信后，在这里查看译文。" : "自动识别中英文，并翻译成另一种语言。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if !model.emailContext.isEmpty {
                    if model.requiresKeyAuthorization && TranslationDirection.detect(model.emailContext) != .undetermined {
                        Button("连接 AI 后翻译") { model.workspace = .settings }
                    } else { Button("翻译来信") { translateMailContext() }.disabled(model.busy) }
                }
            }.padding(.top, 12)
        }
    }

    private func mailReplyPanel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("你想怎么回复").font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu("常用回复") {
                    Button("收到，谢谢") { model.emailIntent = "已收到，谢谢。"; mailFocus = .intent }
                    Button("确认后回复") { model.emailIntent = "我确认一下，稍后回复你。"; mailFocus = .intent }
                    Button("补充详情") { model.emailIntent = "请提供更多详情。"; mailFocus = .intent }
                }.controlSize(.small).fixedSize().disabled(model.busy)
            }
            emailTextArea(text: $model.emailIntent, placeholder: "写下回复要点，中英文均可。将结合来信整理成完整邮件。", label: "回复意图（自动识别语言）", height: 112, field: .intent)
            HStack {
                Picker("语气", selection: $model.emailTone) {
                    Text("简洁").tag("简洁专业")
                    Text("正式").tag("正式礼貌")
                    Text("友好").tag("友好自然")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 200).disabled(model.busy)
                Spacer(minLength: 10)
                Button {
                    if model.requiresKeyAuthorization { model.workspace = .settings }
                    else { mailAction = .reply; model.generateEmail() }
                } label: {
                    Label(model.requiresKeyAuthorization ? "连接 AI" : (model.busy && mailAction == .reply ? "生成中…" : (model.emailReply.isEmpty ? "生成回复" : "重新生成")), systemImage: model.requiresKeyAuthorization ? "lock" : "sparkles")
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || !model.emailDraft.canGenerate)
            }
            Divider().padding(.vertical, 4)
            if model.emailReply.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.emailDraft.replyDirection.targetLanguage + "回复").font(.system(size: 13, weight: .medium))
                    Text(model.busy && mailAction == .reply ? "正在根据你的意思起草…" : "写下回复要点，生成可直接发送的完整邮件正文。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text(model.emailDraft.replyDirection.targetLanguage + "回复").font(.system(size: 13, weight: .semibold))
                    if model.emailDraft.replyIsStale {
                        Text("待更新").font(.system(size: 11)).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button {
                        model.copy(model.emailReply); copiedReply = true
                    } label: {
                        Label(copiedReply ? "已复制" : "复制回复", systemImage: copiedReply ? "checkmark" : "doc.on.doc")
                    }.controlSize(.small).disabled(model.busy || !model.emailDraft.canCopyReply)
                }
                if model.emailDraft.replyIsStale {
                    Text("来信或回复意思已改变，请重新生成，或直接修改下面的回复。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                emailTextArea(text: $model.emailReply, placeholder: "回复", label: model.emailDraft.replyDirection.targetLanguage + "回复", height: emailReplyHeight(width: width), field: .reply)
                if !model.replyMeaning.isEmpty && !model.emailDraft.replyIsStale {
                    DisclosureGroup("对照翻译", isExpanded: $showReplyMeaning) {
                        Text(model.replyMeaning).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 7)
                    }.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }.padding(.top, 4)
    }

    private func acceptMailDrop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = model.importDroppedImages(providers, to: .email)
        if accepted { focusReplyAfterImport = true; mailTab = .source }
        return accepted
    }

    private func importMail(paste: Bool) {
        focusReplyAfterImport = true
        model.importImage(paste: paste)
        if !model.busy {
            focusReplyAfterImport = false
            if model.error == nil && !model.emailContext.isEmpty { mailFocus = .intent }
        }
    }

    private func translateMailContext() {
        mailAction = .translate
        model.translateEmailContext()
    }

    private func emailReplyHeight(width: CGFloat) -> CGFloat {
        let bounds = (model.emailReply as NSString).boundingRect(with: NSSize(width: max(150, width - 38), height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)])
        return min(320, max(110, ceil(bounds.height) + 40))
    }

    private func emailTextArea(text: Binding<String>, placeholder: String, label: String, height: CGFloat, field: MailField) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder).font(.system(size: 14)).foregroundStyle(.secondary.opacity(0.7))
                    .padding(.horizontal, 16).padding(.vertical, 15).allowsHitTesting(false)
            }
            TextEditor(text: text).font(.system(size: 14)).lineSpacing(3).scrollContentBackground(.hidden).padding(10)
                .focused($mailFocus, equals: field).disabled(model.busy).accessibilityLabel(label)
        }.frame(height: height).frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var voiceMenu: some View {
        Menu {
            ForEach(EnglishMaleVoice.available, id: \.identifier) { voice in
                Button {
                    model.voiceIdentifier = voice.identifier
                } label: {
                    if (model.voiceIdentifier.isEmpty && voice.identifier == EnglishMaleVoice.available.first?.identifier) || model.voiceIdentifier == voice.identifier {
                        Label("\(voice.name) · \(voice.language)", systemImage: "checkmark")
                    } else { Text("\(voice.name) · \(voice.language)") }
                }
            }
        } label: { Label("男声 · \(model.voiceName)", systemImage: "person.wave.2") }
            .disabled(output.isSpeaking)
    }

    private var speakView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                voiceMenu
                Text(microphone.detectedLanguage.isEmpty ? "中英自动识别" : "识别：" + microphone.detectedLanguage)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let device = model.outputDeviceName {
                    Text("→ \(device)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Button("配置发送通道") { model.workspace = .settings }.controlSize(.small)
                }
                Spacer()
                Toggle("自动发送", isOn: $model.autoSend).toggleStyle(.checkbox).font(.system(size: 12))
                Button { showVoiceHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).accessibilityLabel("语音使用帮助")
                    .popover(isPresented: $showVoiceHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("中英录音自动识别 → 英文翻译 → 男声回复").font(.headline)
                            Text("先试听，再发送。Teams 或飞书麦克风选择同一个虚拟设备，扬声器选择耳机。输出到设备不代表对方已听到。")
                            Text("⌘⇧R 录音 / 结束（应用内）\n⌘. 停止语音")
                        }.font(.system(size: 12)).padding(20).frame(width: 320)
                    }
            }.controlSize(.small)
            HStack(spacing: 18) {
                editor("发言内容", text: $model.chineseSpeech, placeholder: "说中文或英文，也可直接输入…")
                    .disabled(microphone.isRunning || microphone.isTranscribing)
                    .overlay(alignment: .bottomLeading) {
                        if microphone.isRunning || microphone.isTranscribing {
                            ScrollView { Text(microphone.partial.isEmpty ? (microphone.isTranscribing ? "正在本机识别中英文…" : "正在听中英文…") : microphone.partial).font(.system(size: 15)).padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 150).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(10)
                        }
                    }
                editor("英文 · 可编辑", text: $model.englishSpeech, placeholder: "英文回复，可在发送前修改。")
                    .disabled(microphone.isRunning || microphone.isTranscribing)
            }
            HStack(spacing: 10) {
                Button(microphone.isRunning ? "结束并翻译" : "录音", systemImage: microphone.isRunning ? "stop.circle.fill" : "mic.fill") { model.toggleMicrophone() }
                    .buttonStyle(.bordered).tint(microphone.isRunning ? .red : accent)
                    .disabled(model.transitioningAudio || model.busy || output.isSpeaking)
                Button("翻译", systemImage: "arrow.right") { model.translateSpeech() }
                    .disabled(model.busy || microphone.isRunning || microphone.isTranscribing || model.transitioningAudio || model.chineseSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if output.isSpeaking || model.speechPending || (microphone.isTranscribing && !microphone.isRunning) {
                    Button("停止", systemImage: "stop.fill") { model.stopSpeech() }.buttonStyle(.borderedProminent)
                } else {
                    Button("试听男声", systemImage: "speaker.wave.2") { model.play(meeting: false) }.disabled(microphone.isRunning || microphone.isTranscribing || model.transitioningAudio)
                    Button("发送到会议", systemImage: "arrow.up") { model.play(meeting: true) }
                        .buttonStyle(.borderedProminent)
                        .disabled(microphone.isRunning || model.busy || model.transitioningAudio || model.outputDeviceName == nil || model.englishSpeech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.controlSize(.large)
            if model.speechPending {
                Label("正在翻译发言；点击停止可取消本次发送。", systemImage: "ellipsis.bubble")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if output.isSpeaking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(output.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Label(model.requiresKeyAuthorization ? "DeepSeek · 等待密钥授权" : (model.savedConfiguration.model.isEmpty ? "尚未连接 AI" : "DeepSeek · \(model.savedConfiguration.model)"), systemImage: model.requiresKeyAuthorization ? "lock" : (model.savedConfiguration.model.isEmpty ? "circle" : "checkmark.circle.fill"))
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(model.savedConfiguration.model.isEmpty ? Color.secondary : accent)
                    Spacer()
                    if model.requiresKeyAuthorization {
                        Button(model.authorizingKey ? "等待授权…" : "授权密钥") { model.authorizeSavedKey() }
                            .buttonStyle(.borderedProminent).disabled(model.authorizingKey)
                    }
                    if !model.savedConfiguration.model.isEmpty {
                        Button(showConnection ? "收起" : "编辑连接") { showConnection.toggle() }.controlSize(.small)
                    }
                }
                if model.savedConfiguration.model.isEmpty || showConnection { connectionFields }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    sectionTitle("声音与发送", icon: "speaker.wave.2")
                    HStack {
                        Text("英文声音").font(.system(size: 12)).foregroundStyle(.secondary)
                        voiceMenu
                        Spacer()
                        Button("试听男声") { model.play(meeting: false) }.disabled(output.isSpeaking || microphone.isRunning)
                    }
                    HStack {
                        Picker("会议发送通道", selection: Binding(get: { model.configuration.outputDeviceUID }, set: { model.setOutputDevice($0) })) {
                            Text("选择虚拟音频设备").tag("")
                            if !model.configuration.outputDeviceUID.isEmpty && !model.devices.contains(where: { $0.id == model.configuration.outputDeviceUID }) {
                                Text("设备已断开").tag(model.configuration.outputDeviceUID)
                            }
                            ForEach(model.devices) { Text($0.name).tag($0.id) }
                        }
                        Button("刷新") { model.refreshDevices() }
                    }
                    Text("选择后自动保存。在 Teams 或飞书中把麦克风设为同一设备，扬声器设为耳机。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    DisclosureGroup("连接说明") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("没有合适设备时，可安装 BlackHole 2ch 后刷新。保持 Mac 默认输入为真实麦克风；不要将系统全部声音送入虚拟设备，以免回声。")
                            Link("BlackHole 官方网站", destination: URL(string: "https://existential.audio/blackhole/")!)
                            Text("完成后在 Teams 或飞书中测试通话确认，软件不会自动修改会议软件设置。")
                        }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                    }.font(.system(size: 12))
                }
                Divider()
                DisclosureGroup("权限与数据") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("截图和中英文语音识别都在本机完成；识别后的文字发给配置的 AI 服务翻译。语音片段只在私有临时目录暂存，识别完成、取消或正常退出后清理。输入和回复只保留在内存，退出前请复制需要的内容。")
                        Button("打开系统隐私设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!) }
                    }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.system(size: 12))
            }.frame(maxWidth: 720, alignment: .leading).padding(.bottom, 20)
        }
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("服务地址", hint: "Chat Completions 兼容接口") { TextField("https://api.deepseek.com", text: $model.configuration.baseURL) }
            field("模型", hint: "服务商提供的模型 ID") { TextField("deepseek-flash", text: $model.configuration.model) }
            field("API 密钥", hint: "保存到 Mac 钥匙串") { SecureField("API Key", text: $model.apiKey) }
            HStack {
                Button("保存连接") { model.save() }.buttonStyle(.borderedProminent)
                Button("测试") { model.testConnection() }.disabled(model.busy)
                Spacer()
                Button("导入本机 DeepSeek") { model.importLocalDeepSeek() }.disabled(model.busy)
            }
            Text("翻译内容会发送至该服务；测试连接可能产生少量费用。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 16, weight: .semibold))
    }
    private func field<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.system(size: 12, weight: .medium)); Text(hint).font(.system(size: 11)).foregroundStyle(.secondary) }
            content().textFieldStyle(.roundedBorder).font(.system(size: 13)).accessibilityLabel(title)
        }
    }
    private func editor(_ title: String?, text: Binding<String>, placeholder: String, acceptsImages: Bool = false, showsTitle: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            if showsTitle, let title { Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty { Text(placeholder).font(.system(size: 15)).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 18).allowsHitTesting(false) }
                TextEditor(text: text).font(.system(size: 15)).scrollContentBackground(.hidden).padding(10)
                    .accessibilityLabel(title ?? placeholder)
                    .disabled(model.busy)
                    .onDrop(of: acceptsImages ? ImageImport.dropTypes : [], isTargeted: $translationDropTarget) { providers in
                        acceptsImages && model.importDroppedImages(providers, to: .translation)
                    }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(acceptsImages && translationDropTarget ? accent : Color.primary.opacity(0.07), lineWidth: acceptsImages && translationDropTarget ? 2 : 1))
                .onDrop(of: acceptsImages ? ImageImport.dropTypes : [], isTargeted: $translationDropTarget) { providers in
                    acceptsImages && model.importDroppedImages(providers, to: .translation)
                }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func result(_ title: String, text: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Button("复制", systemImage: "doc.on.doc") { model.copy(text) }.disabled(text.isEmpty).controlSize(.small)
                Spacer(minLength: 0)
            }.frame(height: 26)
            ScrollView {
                Text(text.isEmpty ? placeholder : text).font(.system(size: 15)).lineSpacing(6)
                    .foregroundStyle(text.isEmpty ? Color.secondary.opacity(0.6) : .primary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(18)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FloatingCaptions: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechInput
    var body: some View { ConversationFloatingView(conversation: model.conversation) }
}
