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
        KeyboardSettings.abcUsesFlickLayoutKey,
        store: KeyboardSettings.sharedDefaults
    ) private var abcUsesFlickLayout = KeyboardSettings.abcUsesFlickLayout
    @AppStorage(
        KeyboardSettings.characterVariantKey,
        store: KeyboardSettings.sharedDefaults
    ) private var characterVariant = KeyboardSettings.characterVariant
    @State private var showsClearConfirmation = false
    @State private var learningMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("鍵盤測試")
                        .font(.headline)

                    TextEditor(text: $text)
                        .font(.body)
                        .frame(height: 160)
                        .padding(8)
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                        }
                        .accessibilityLabel("鍵盤測試文字")

                    Group {
                        LabeledContent("字形轉換") {
                            Picker("字形轉換", selection: $characterVariant) {
                                ForEach(CharacterVariant.allCases, id: \.self) { variant in
                                    Text(variant.title).tag(variant)
                                }
                            }
                            .labelsHidden()
                        }
                        Text("候選與建議字詞使用的字形。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("顯示四方向符號", isOn: $showsDirectionalSymbols)
                        Text("關閉後注音與標點按鍵只顯示中央符號。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("ABC 模式使用九宮格", isOn: $abcUsesFlickLayout)
                        Text("開啟時以滑動選擇字母；關閉後改用 QWERTY 全鍵盤。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("選完字後自動提交", isOn: $autoCommitComposition)
                        Text("關閉後需按「確定」提交組字內容。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("記憶選字", isOn: $remembersSelections)
                        Text("提交後記住新詞與選字次數。鍵盤需要開啟「允許完整取用」才能寫入；資料只保存在此裝置。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("清除學習資料", role: .destructive) {
                            showsClearConfirmation = true
                        }

                        NavigationLink("自訂詞彙") {
                            CustomWordsView()
                        }
                        Text("自行加入的詞彙與讀音，可隨時編輯。與自動記憶的選字不同，不會被清除學習資料刪除。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(KeyboardSettings.appGroupIdentifier == nil)

                    if KeyboardSettings.appGroupIdentifier == nil {
                        Text("無法開啟鍵盤的共享設定。請確認安裝時保留鍵盤擴充功能，且主 App 與擴充功能的簽署都包含同一個 App Group。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let learningMessage {
                        Text(learningMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink("第三方授權") {
                        ThirdPartyLicensesView()
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(Self.appDisplayName)
            .onAppear(perform: KeyboardSettings.logAppGroupStatus)
            .confirmationDialog("清除所有新詞與選字次數？", isPresented: $showsClearConfirmation) {
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

#Preview {
    ContentView()
}
