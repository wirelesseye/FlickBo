import SwiftUI

/// Words the user adds by hand. Unlike remembered selections these can be edited,
/// and "clear learning data" leaves them alone.
struct CustomWordsView: View {
    @State private var words: [UserWordKey] = []
    @State private var text = ""
    @State private var reading = ""
    @State private var message: String?
    @FocusState private var focusedField: Field?

    private enum Field { case text, reading }

    var body: some View {
        List {
            Section {
                TextField("詞彙，例如：滑注音", text: $text)
                    .focused($focusedField, equals: .text)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .reading }
                TextField("注音，例如：ㄏㄨㄚˊ ㄓㄨˋ ㄧㄣ", text: $reading)
                    .focused($focusedField, equals: .reading)
                    .submitLabel(.done)
                    .onSubmit(add)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("加入詞彙", action: add)
                    .disabled(text.isEmpty || reading.isEmpty)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("新增")
            } footer: {
                Text("每個字對應一個音節，音節以空格分隔；一聲可省略聲調符號，輕聲寫在音節前（˙ㄉㄜ）。自訂詞彙會優先顯示，且不會被「清除學習資料」刪除。")
            }

            Section("自訂詞彙") {
                if words.isEmpty {
                    Text("尚無自訂詞彙")
                        .foregroundStyle(.secondary)
                }
                ForEach(words, id: \.self) { word in
                    HStack {
                        Text(word.text)
                        Spacer()
                        Text(word.readingText)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .onDelete(perform: delete)
            }
        }
        .navigationTitle("自訂詞彙")
        .toolbar { EditButton() }
        .onAppear(perform: reload)
    }

    private func openStore() throws -> UserLearningStore {
        guard let url = KeyboardSettings.userLearningURL else {
            throw UserLearningError.database("App Group 容器不可用")
        }
        return try UserLearningStore(url: url, writable: true)
    }

    private func reload() {
        do {
            words = try openStore().customWords()
        } catch {
            message = "讀取失敗：\(error.localizedDescription)"
        }
    }

    private func add() {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        guard let key = UserWordKey(text: word, reading: reading) else {
            message = "請確認詞彙為 1 至 8 個漢字，注音只含注音符號與聲調符號，且每個字對應一個音節（以空格分隔）。"
            return
        }
        do {
            if try openStore().addCustomWord(key) {
                text = ""
                reading = ""
                message = "已加入「\(word)」。"
                focusedField = .text
                reload()
            } else {
                message = "「\(word)」已有相同的讀音。"
            }
        } catch {
            message = "加入失敗：\(error.localizedDescription)"
        }
    }

    private func delete(at offsets: IndexSet) {
        do {
            let store = try openStore()
            for index in offsets { try store.removeCustomWord(words[index]) }
            reload()
        } catch {
            message = "刪除失敗：\(error.localizedDescription)"
        }
    }
}

#Preview {
    NavigationStack { CustomWordsView() }
}
