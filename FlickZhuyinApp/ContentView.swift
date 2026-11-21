import SwiftUI

struct ContentView: View {
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
                        LabeledContent("字形") {
                            Picker("字形", selection: $characterVariant) {
                                ForEach(CharacterVariant.allCases, id: \.self) { variant in
                                    Text(variant.title).tag(variant)
                                }
                            }
                            .labelsHidden()
                        }
                        Text(characterVariant.settingsDescription)
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
            .navigationTitle("FlickZhuyin")
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

private extension CharacterVariant {
    var title: String {
        switch self {
        case .taiwan: "臺灣"
        case .hongKong: "香港"
        case .mainland: "大陸（簡體）"
        case .traditional: "傳承字形"
        }
    }

    var settingsDescription: String {
        switch self {
        case .taiwan: "例如「為什麼」「裡面」；臺灣用詞（例如「軟體」「程式碼」）排序較前。"
        case .hongKong: "例如「為什麼」「裏面」，採用香港常用字形。"
        case .mainland: "例如「为什么」「里面」，候選轉為簡體字。"
        case .traditional: "例如「爲什麼」「裏面」，即 OpenCC 標準繁體，與內建詞庫相同。"
        }
    }
}
