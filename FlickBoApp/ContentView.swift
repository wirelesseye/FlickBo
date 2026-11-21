import SwiftUI

struct ContentView: View {
    private static let appDisplayName =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "FlickBo"

    @State private var text = ""
    @AppStorage(
        KeyboardSettings.showsDirectionalSymbolsKey,
        store: KeyboardSettings.sharedDefaults
    ) private var showsDirectionalSymbols = KeyboardSettings.showsDirectionalSymbols
    @AppStorage(
        KeyboardSettings.autoCommitCompositionKey,
        store: KeyboardSettings.sharedDefaults
    ) private var autoCommitComposition = KeyboardSettings.autoCommitComposition
    @AppStorage(
        KeyboardSettings.remembersSelectionsKey,
        store: KeyboardSettings.sharedDefaults
    ) private var remembersSelections = KeyboardSettings.remembersSelections
    @AppStorage(
        KeyboardSettings.showsEmojiCandidatesKey,
        store: KeyboardSettings.sharedDefaults
    ) private var showsEmojiCandidates = KeyboardSettings.showsEmojiCandidates
    @AppStorage(
        KeyboardSettings.abcUsesFlickLayoutKey,
        store: KeyboardSettings.sharedDefaults
    ) private var abcUsesFlickLayout = KeyboardSettings.abcUsesFlickLayout
    @AppStorage(
        KeyboardSettings.characterVariantKey,
        store: KeyboardSettings.sharedDefaults
    ) private var characterVariant = KeyboardSettings.characterVariant
    @State private var showsClearConfirmation = false
    @State private var learningMessage: String?

    private var sharedSettingsAvailable: Bool {
        KeyboardSettings.appGroupIdentifier != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.body)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("在這裡試用鍵盤⋯")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("鍵盤測試文字")
                } header: {
                    Text("鍵盤測試")
                }

                if !sharedSettingsAvailable {
                    Section {
                        Label {
                            Text("無法開啟鍵盤的共享設定。請確認安裝時保留鍵盤擴充功能，且主 App 與擴充功能的簽署都包含同一個 App Group。")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Group {
                    Section {
                        Picker(selection: $characterVariant) {
                            ForEach(CharacterVariant.allCases, id: \.self) { variant in
                                Text(variant.title).tag(variant)
                            }
                        } label: {
                            SettingLabel("字形轉換", systemImage: "character.book.closed", color: .indigo)
                        }
                    } header: {
                        Text("字形")
                    } footer: {
                        Text("候選與建議字詞使用的字形。")
                    }

                    Section {
                        Toggle(isOn: $showsDirectionalSymbols) {
                            SettingLabel("顯示四方向符號", systemImage: "arrow.up.and.down.and.arrow.left.and.right", color: .blue)
                        }
                        Toggle(isOn: $abcUsesFlickLayout) {
                            SettingLabel("ABC 模式使用九宮格", systemImage: "square.grid.3x3", color: .teal)
                        }
                    } header: {
                        Text("鍵盤配置")
                    } footer: {
                        Text("關閉四方向符號後，注音與標點按鍵只顯示中央符號。ABC 九宮格以滑動選擇字母；關閉後改用 QWERTY 全鍵盤。")
                    }

                    Section {
                        Toggle(isOn: $autoCommitComposition) {
                            SettingLabel("選完字後自動提交", systemImage: "return", color: .green)
                        }
                        Toggle(isOn: $remembersSelections) {
                            SettingLabel("記憶選字", systemImage: "brain", color: .pink)
                        }
                        Toggle(isOn: $showsEmojiCandidates) {
                            SettingLabel("候選詞顯示繪文字", systemImage: "face.smiling", color: .yellow)
                        }
                        NavigationLink {
                            CustomWordsView()
                        } label: {
                            SettingLabel("自訂詞彙", systemImage: "text.book.closed", color: .orange)
                        }
                    } header: {
                        Text("輸入")
                    } footer: {
                        Text("關閉自動提交後，需按「確定」提交組字內容。記憶選字會在提交後記住新詞與選字次數，鍵盤需開啟「允許完整取用」才能寫入，資料只保存在此裝置。繪文字接在對應的詞後面，例如「笑」之後出現 😄，不會影響記憶選字。自訂詞彙可隨時編輯，不會被清除學習資料刪除。")
                    }
                }
                .disabled(!sharedSettingsAvailable)

                Section {
                    NavigationLink {
                        ThirdPartyLicensesView()
                    } label: {
                        SettingLabel("第三方授權", systemImage: "doc.text", color: .gray)
                    }
                } header: {
                    Text("關於")
                }

                Section {
                    Button(role: .destructive) {
                        showsClearConfirmation = true
                    } label: {
                        Text("清除學習資料")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!sharedSettingsAvailable)
                } footer: {
                    if let learningMessage {
                        Text(learningMessage)
                    } else {
                        Text("刪除自動記憶的新詞與選字次數，自訂詞彙不受影響。")
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Self.appDisplayName)
            .onAppear(perform: KeyboardSettings.logAppGroupStatus)
            .confirmationDialog(
                "清除所有新詞與選字次數？",
                isPresented: $showsClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("清除學習資料", role: .destructive) {
                    Task {
                        do {
                            guard let url = KeyboardSettings.userLearningURL else {
                                throw UserLearningError.database("App Group 容器不可用")
                            }
                            let store = try UserLearningStore(url: url, writable: true)
                            try store.clear()
                            learningMessage = "已清除學習資料。"
                        } catch {
                            learningMessage = "清除失敗：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
}

/// A settings row label with a tinted rounded-square icon, like the Settings app.
private struct SettingLabel: View {
    let title: String
    let systemImage: String
    let color: Color

    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

#Preview {
    ContentView()
}
