import SwiftUI
import AppKit

private let meetingAccent = accent

struct MeetingConversationView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var conversation: MeetingConversation
    @State private var showAudio = false
    @State private var followLatest = true
    @State private var installedVoices = EnglishMaleVoice.available

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            controls
            if let failure = conversation.failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.requiresKeyAuthorization {
                HStack {
                    Label("先连接已保存的 AI，即可开始翻译。", systemImage: "lock")
                    Spacer()
                    Button(model.authorizingKey ? "等待授权…" : "连接 AI") { model.authorizeSavedKey() }
                        .disabled(model.authorizingKey)
                }.font(.system(size: 12)).padding(12)
                    .background(meetingAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            directions
            transcript
            footer
        }
        .sheet(isPresented: $showAudio) { audioSetup }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in installedVoices = EnglishMaleVoice.available }
    }
    private var controls: some View {
        HStack(spacing: 18) {
            Picker("会议软件", selection: $conversation.platform) {
                ForEach(MeetingPlatform.allCases) { Text($0.rawValue).tag($0) }
            }.frame(width: 150).disabled(!conversation.canConfigure)
            Picker("翻译模式", selection: $conversation.mode) {
                ForEach(ConversationMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).frame(width: 190).disabled(!conversation.canConfigure)
            Spacer(minLength: 4)
            Button("连接音频", systemImage: "cable.connector") { model.refreshDevices(); showAudio = true }
                .disabled(!conversation.canConfigure)
            Button { model.toggleFloating() } label: { Image(systemName: "pip") }
                .help("浮动字幕").accessibilityLabel("浮动字幕")
            Menu {
                Button("导出对话") { conversation.export() }.disabled(conversation.turns.isEmpty)
                Button("清空对话") { conversation.clear() }.disabled(conversation.turns.isEmpty || !conversation.canConfigure)
                Divider()
                Button("单句翻译…") { model.workspace = .speak }.disabled(conversation.isActive)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 22).accessibilityLabel("更多会议操作")
        }.controlSize(.small)
    }
    private var directions: some View {
        HStack(spacing: 0) {
            direction("我说中文", result: conversation.mode == .captions ? "本模式不发送语音" : "对方听英文", icon: "mic", active: conversation.mode == .dialogue && !conversation.muted)
            Divider().frame(height: 30).padding(.horizontal, 22)
            direction("对方说英文", result: conversation.mode == .captions || !conversation.readChinese ? "我看中文字幕" : "我听中文 · 同时看字幕", icon: "headphones", active: true)
        }.padding(.horizontal, 20).padding(.vertical, 18)
            .background(meetingAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private func direction(_ title: String, result: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 21, weight: .light)).foregroundStyle(active ? meetingAccent : Color.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(result).font(.system(size: 15, weight: .medium))
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if conversation.turns.isEmpty { emptyState }
                    ForEach(conversation.turns) { turn in ConversationTurnView(turn: turn).id(turn.id) }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(24)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
            .onChange(of: conversation.turns.last?.id) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: conversation.turns.last?.translation) { _, _ in if followLatest { proxy.scrollTo("latest", anchor: .bottom) } }
            .onChange(of: followLatest) { _, follow in if follow { proxy.scrollTo("latest", anchor: .bottom) } }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: conversation.mode == .dialogue ? "bubble.left.and.bubble.right" : "captions.bubble")
                .font(.system(size: 38, weight: .ultraLight)).foregroundStyle(meetingAccent)
            Text(conversation.phase == .running ? "正在听，直接开始说话" : "像平常一样，继续对话")
                .font(.system(size: 23, weight: .medium))
            Text(conversation.mode == .dialogue
                 ? "戴上耳机，打开 \(conversation.platform.rawValue) 会议。\n开始后按停顿自动翻译，不必逐句录音、翻译或发送。"
                 : "打开 \(conversation.platform.rawValue) 桌面客户端。\n只翻译对方的发言，不录你的麦克风，不发送语音。")
                .font(.system(size: 13)).lineSpacing(5).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if conversation.mode == .dialogue && !conversation.routeConfirmed {
                Button("首次使用：连接音频") { model.refreshDevices(); showAudio = true }.padding(.top, 4)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 64)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    if conversation.isActive { conversation.stop() }
                    else { conversation.start(device: model.savedConfiguration.outputDeviceUID, voice: model.voiceIdentifier) }
                } label: {
                    Label(conversation.phase == .starting ? "取消连接" : (conversation.phase == .running ? "暂停对话" : (conversation.phase == .stopping ? "正在停止…" : "开始对话")),
                          systemImage: conversation.isActive ? "pause.fill" : "play.fill")
                }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(conversation.phase == .stopping || model.requiresKeyAuthorization || model.savedConfiguration.model.isEmpty)
                if conversation.mode == .dialogue {
                    Button { conversation.toggleMute() } label: {
                        Label(conversation.muted ? "取消静音" : "静音自己", systemImage: conversation.muted ? "mic.slash.fill" : "mic")
                    }.disabled(conversation.phase != .running)
                    Toggle("中文朗读", isOn: $conversation.readChinese).toggleStyle(.checkbox).font(.system(size: 12))
                }
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    if conversation.phase == .starting || conversation.phase == .stopping { ProgressView().controlSize(.mini) }
                    else { Circle().fill(conversation.phase == .running ? meetingAccent : Color.secondary.opacity(0.5)).frame(width: 6, height: 6) }
                    Text(conversation.status).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("按句翻译，存在识别与播放延迟。对话仅保留到退出；需要时导出。")
                Spacer()
                Toggle("跟随最新", isOn: $followLatest).toggleStyle(.checkbox)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var audioSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("连接 \(conversation.platform.rawValue) 音频").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("完成") { showAudio = false }.keyboardShortcut(.defaultAction)
            }
            Text("只需设置一次。会中保持耳机连接，让原声与译声走各自的通道。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 18) {
                setupStep("1", title: "把英文送进会议", detail: "在 \(conversation.platform.rawValue) 的音频设置里，将麦克风选为下方同名通道，并取消静音。") {
                    HStack {
                        Picker("会议麦克风", selection: Binding(get: { model.savedConfiguration.outputDeviceUID }, set: { model.setOutputDevice($0) })) {
                            Text("选择虚拟音频通道").tag("")
                            if !model.savedConfiguration.outputDeviceUID.isEmpty && !model.devices.contains(where: { $0.id == model.savedConfiguration.outputDeviceUID && $0.isMeetingLoopback }) {
                                Text("通道不可用").tag(model.savedConfiguration.outputDeviceUID)
                            }
                            ForEach(model.devices.filter { output in output.isMeetingLoopback && AudioDevices.inputs().contains(where: { $0.id == output.id }) }) { Text($0.name).tag($0.id) }
                        }.labelsHidden()
                        Button("刷新") { model.refreshDevices() }
                    }
                }
                setupStep("2", title: "用耳机听中文", detail: "将 Mac 和 \(conversation.platform.rawValue) 的扬声器都设为耳机。Mac 的输入仍选真实麦克风；不要选虚拟通道。") {
                    Button("打开 Mac 声音设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!) }
                }
                setupStep("3", title: "选择英文声音", detail: "你的中文停顿后，自动翻译并用此声音发送。对方原声仍可听到，中文译声随后播放。") {
                    Picker("英文声音", selection: $model.voiceIdentifier) {
                        Text("自动优选高质量男声").tag("")
                        ForEach(installedVoices, id: \.identifier) { Text("\(EnglishMaleVoice.displayName($0)) · \($0.language)").tag($0.identifier) }
                    }.labelsHidden().frame(maxWidth: 280)
                    if let voice = try? EnglishMaleVoice.natural(identifier: model.voiceIdentifier) {
                        Text("当前：\(EnglishMaleVoice.displayName(voice))。本机合成，不额外收取语音费用。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        if voice.quality.rawValue == 1 {
                            Text("目前是普通版。下载同名增强／高级版后会自动优先使用，音色更自然。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Button("下载增强声音…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!) }
                }
            }
            if !model.devices.contains(where: \.isMeetingLoopback) {
                Label("尚未检测到可用通道，请安装 BlackHole 2ch 后刷新。", systemImage: "cable.connector.slash")
                    .font(.system(size: 12)).foregroundStyle(.orange)
            }
            Toggle("我已戴好耳机，并在 \(conversation.platform.rawValue) 中选好上面的麦克风", isOn: $conversation.routeConfirmed)
                .font(.system(size: 12)).disabled(!model.devices.contains(where: { $0.id == model.savedConfiguration.outputDeviceUID && $0.isMeetingLoopback }))
            DisclosureGroup("没有虚拟通道，或想只看字幕？") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("双向语音需要 BlackHole 2ch 等虚拟音频设备。安装后刷新，再按上面的步骤选择通道；“仅字幕”无需虚拟设备。暂不支持网页版会议。")
                    Link("BlackHole 官方安装说明", destination: URL(string: "https://existential.audio/blackhole/")!)
                    Text("开始后，识别在本机完成，文字发送至你配置的 AI 服务翻译。请按会议约定使用。")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.system(size: 12))
        }.padding(26).frame(width: 560)
    }
    private func setupStep<Content: View>(_ number: String, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 12, weight: .semibold)).foregroundStyle(meetingAccent)
                .frame(width: 24, height: 24).background(meetingAccent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                content().controlSize(.small)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConversationTurnView: View {
    let turn: ConversationTurn
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: turn.side == .mine ? "mic" : "headphones")
                .font(.system(size: 13)).foregroundStyle(turn.side == .mine ? meetingAccent : Color.secondary)
                .frame(width: 28, height: 28).background(Color.primary.opacity(0.04), in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(turn.side == .mine ? "我 · 中文 → 英文" : "对方 · 英文 → 中文").font(.system(size: 11, weight: .medium))
                    Text(turn.date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(turn.state.rawValue).foregroundStyle(turn.state == .failed ? Color.red : Color.secondary)
                }.font(.system(size: 10))
                Text(turn.translation.isEmpty ? turn.source : turn.translation).font(.system(size: 17, weight: .medium)).lineSpacing(4).textSelection(.enabled)
                if !turn.translation.isEmpty { Text(turn.source).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationFloatingView: View {
    @ObservedObject var conversation: MeetingConversation
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(conversation.platform.rawValue) · \(conversation.status)").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if conversation.isActive { Button("暂停") { conversation.stop() }.controlSize(.small) }
            }
            if let turn = conversation.turns.last(where: { $0.side == .partner }) {
                Text(turn.translation.isEmpty ? turn.source : turn.translation).font(.system(size: 22, weight: .medium)).textSelection(.enabled)
                if !turn.translation.isEmpty { Text(turn.source).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            } else { Text("等待对方发言…").font(.system(size: 22)).foregroundStyle(.secondary) }
            if let mine = conversation.turns.last(where: { $0.side == .mine }) {
                Text("我：\(mine.translation.isEmpty ? mine.source : mine.translation)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            if let failure = conversation.failure { Text(failure).font(.system(size: 11)).foregroundStyle(.red) }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.background(.regularMaterial)
    }
}

struct ConversationActivityView: View {
    @ObservedObject var conversation: MeetingConversation
    var body: some View {
        if conversation.isActive {
            Label("\(conversation.platform.rawValue) · \(conversation.phase == .running ? "翻译中" : "连接中")", systemImage: "waveform")
                .font(.system(size: 11)).foregroundStyle(meetingAccent)
            Button("暂停会议") { conversation.stop() }.controlSize(.small)
        }
    }
}
