import UIKit
import os

final class KeyboardViewController: UIInputViewController, UIGestureRecognizerDelegate {
    private static let maximumCandidateCount = 30
    /// Horizontal finger travel that moves the cursor by one character in space-bar cursor mode.
    private static let cursorStepWidth: CGFloat = 9

    private var engine = KeyboardEngine()
    private var keyButtons: [(key: KeyboardKey, button: KeyboardButton)] = []
    private weak var nextKeyboardButton: KeyboardButton?
    private weak var candidateBar: CandidateBarView?
    private weak var expandedCandidatesView: ExpandedCandidateView?
    private weak var keyGrid: UIStackView?
    /// Keys dimmed while the space bar drags the cursor.
    private weak var keyArea: UIView?
    private var cursorDragAnchorX: CGFloat?
    private weak var toneButton: FlickKeyButton?
    private weak var punctuationButton: FlickKeyButton?
    private var heightConstraint: NSLayoutConstraint?
    private var isCandidateListExpanded = false
    private var documentEffectDepth = 0
    private var documentHasMarkedText = false
    private var documentContextBeforeComposition = ""
    private var expectedSuggestionContext: String?
    private var showsDirectionalSymbols = KeyboardSettings.showsDirectionalSymbols
    private var abcUsesFlickLayout = KeyboardSettings.abcUsesFlickLayout
    private var letterKeys: [(base: FlickKeyMapping, button: FlickKeyButton)] = []
    /// Cached per-mode width so the toggle still works without App Group access.
    private var characterWidths: [KeyboardMode: CharacterWidth] = [:]

    private var coordinator: ChineseInputCoordinator?
    private var coordinatorHasFullAccess: Bool?
    private var coordinatorCharacterVariant: CharacterVariant?
    private var coordinatorShowsEmoji: Bool?
    private var isShowingEmojiPanel = false
    private var emojiCatalog: EmojiCatalog?
    private let recentEmoji = RecentEmojiStore(defaults: .standard)
    private let recentSymbols = RecentEmojiStore(defaults: .standard, key: RecentEmojiStore.symbolKey)
    private let recentKaomoji = RecentEmojiStore(defaults: .standard, key: RecentEmojiStore.kaomojiKey)
    private var symbolPalettes: SymbolPalettes?
    private static let paletteKindKey = "paletteKind"
    /// Emoji search shows the keys with a search field on top; document
    /// effects go to `emojiSearchQuery` instead of the host app meanwhile.
    private var isSearchingEmoji = false
    private let emojiSearchQuery = EmojiSearchQuery()
    private lazy var searchEffectApplier = DocumentEffectApplier(client: emojiSearchQuery)
    private var emojiSearchIndex: EmojiSearchIndex?
    private var emojiSearchConverter: (variant: CharacterVariant, converter: CandidateTextConverter)?
    private var lastEmojiSearch: (query: String, results: [String])?
    private weak var emojiSearchField: EmojiSearchFieldView?
    private weak var emojiSearchResults: EmojiSearchResultsView?
    /// The variant in use. Kept here so the toolbar menu still works when the
    /// App Group cannot be written; `settingsCharacterVariant` notices changes
    /// made in the app.
    private var characterVariant = KeyboardSettings.characterVariant
    private var settingsCharacterVariant = KeyboardSettings.characterVariant

    private lazy var effectApplier = DocumentEffectApplier(
        client: TextDocumentProxyClient(proxy: textDocumentProxy)
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        view.isOpaque = false
        view.backgroundColor = .clear
        KeyHaptics.prepare()
        configureHeight()
        rebuildKeyboard()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        KeyboardSettings.logAppGroupStatus()
        let accessChanged = coordinatorHasFullAccess.map { $0 != hasFullAccess } ?? false
        let settingsVariant = KeyboardSettings.characterVariant
        if settingsVariant != settingsCharacterVariant {
            settingsCharacterVariant = settingsVariant
            characterVariant = settingsVariant
            candidateBar?.characterVariant = settingsVariant
        }
        let variantChanged = coordinatorCharacterVariant.map { $0 != characterVariant } ?? false
        let emojiChanged = coordinatorShowsEmoji.map { $0 != KeyboardSettings.showsEmojiCandidates } ?? false
        if accessChanged || variantChanged || emojiChanged {
            resetCoordinator()
        }
        let shows = KeyboardSettings.showsDirectionalSymbols
        let usesFlick = KeyboardSettings.abcUsesFlickLayout
        guard shows != showsDirectionalSymbols || usesFlick != abcUsesFlickLayout else { return }
        showsDirectionalSymbols = shows
        abcUsesFlickLayout = usesFlick
        rebuildKeyboard()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        nextKeyboardButton?.isHidden = !needsInputModeSwitchKey
        updateKeyboardHeight()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        handleHostDocumentChange()
        refreshReturnKeyFace()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        handleHostDocumentChange()
        refreshReturnKeyFace()
    }

    override func handleInputModeList(from view: UIView, with event: UIEvent) {
        super.handleInputModeList(from: view, with: event)
    }

    private func rebuildKeyboard() {
        view.subviews.forEach { $0.removeFromSuperview() }
        keyButtons.removeAll(keepingCapacity: true)
        letterKeys.removeAll(keepingCapacity: true)
        nextKeyboardButton = nil
        candidateBar = nil
        expandedCandidatesView = nil
        keyGrid = nil
        keyArea = nil
        cursorDragAnchorX = nil
        toneButton = nil
        punctuationButton = nil
        emojiSearchField = nil
        emojiSearchResults = nil
        isCandidateListExpanded = false
        engine.characterWidth = characterWidth(for: engine.mode)

        if isShowingEmojiPanel {
            buildEmojiPanel()
            refreshUI()
            view.setNeedsLayout()
            return
        }
        switch engine.mode {
        case .zhuyin: buildZhuyinKeyboard()
        case .number: buildNumberKeyboard()
        case .abc:
            if abcUsesFlickLayout {
                buildGridKeyboard(mode: .abc)
            } else {
                buildABCKeyboard()
            }
        }
        refreshUI()
        view.setNeedsLayout()
    }

    private func buildABCKeyboard() {
        let mainStack = pinnedVerticalStack(spacing: 7)
        // No candidates in ABC mode, so the bar always shows the toolbar.
        addTopArea(to: mainStack)

        let keyboardStack = UIStackView()
        keyboardStack.axis = .vertical
        keyboardStack.spacing = 7
        keyboardStack.distribution = .fillEqually
        mainStack.addArrangedSubview(keyboardStack)
        keyArea = keyboardStack
        for (index, row) in KeyboardLayout.letterRows.enumerated() {
            let rowStack = makeRow()
            if index == 1 {
                rowStack.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
                rowStack.isLayoutMarginsRelativeArrangement = true
            }
            let keys = index == 2 ? KeyboardLayout.thirdRow : row
            keys.forEach { rowStack.addArrangedSubview(makeButton(for: $0)) }
            keyboardStack.addArrangedSubview(rowStack)
        }

        let controlStack = makeControlRow()
        for key in [.nextKeyboard, .modeSwitch, .space, .return] as [KeyboardKey] {
            let button = makeButton(for: key)
            controlStack.addArrangedSubview(button)
            switch key {
            case .nextKeyboard, .modeSwitch:
                button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            case .return:
                button.widthAnchor.constraint(equalToConstant: 92).isActive = true
            default:
                break
            }
        }
        keyboardStack.addArrangedSubview(controlStack)
    }

    private func makeCandidateBar() -> CandidateBarView {
        let candidateBar = CandidateBarView()
        candidateBar.onSelect = { [weak self] candidate in self?.select(candidate) }
        candidateBar.onToggleExpansion = { [weak self] in self?.toggleCandidateExpansion() }
        candidateBar.onVisibleCandidatesChanged = { [weak self] _ in
            self?.refreshExpandedCandidates()
        }
        candidateBar.onOpenSettings = { [weak self] in self?.openContainingApp() }
        candidateBar.onDismissKeyboard = { [weak self] in self?.dismissKeyboard() }
        candidateBar.characterWidth = characterWidth(for: engine.mode)
        candidateBar.onToggleCharacterWidth = { [weak self] in self?.toggleCharacterWidth() }
        candidateBar.characterVariant = characterVariant
        candidateBar.onSelectCharacterVariant = { [weak self] variant in self?.selectCharacterVariant(variant) }
        candidateBar.heightAnchor.constraint(equalToConstant: 40).isActive = true
        self.candidateBar = candidateBar
        return candidateBar
    }

    /// The candidate bar, or while searching emoji, the search field above a
    /// row where candidates cover the results while composing.
    private func addTopArea(to stack: UIStackView) {
        let candidateBar = makeCandidateBar()
        guard isSearchingEmoji else {
            stack.addArrangedSubview(candidateBar)
            return
        }
        let field = EmojiSearchFieldView()
        field.onBack = { [weak self] in self?.closeEmojiSearch() }
        field.onClear = { [weak self] in self?.clearEmojiSearch() }
        field.heightAnchor.constraint(equalToConstant: Self.emojiSearchFieldHeight).isActive = true
        let results = EmojiSearchResultsView()
        results.onSelect = { [weak self] emoji in self?.insertSearchedEmoji(emoji) }
        let row = UIView()
        for subview in [results, candidateBar] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                subview.topAnchor.constraint(equalTo: row.topAnchor),
                subview.bottomAnchor.constraint(equalTo: row.bottomAnchor)
            ])
        }
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(row)
        emojiSearchField = field
        emojiSearchResults = results
        lastEmojiSearch = nil
    }

    private func buildZhuyinKeyboard() {
        buildGridKeyboard(mode: .zhuyin)
    }

    private func buildNumberKeyboard() {
        buildGridKeyboard(mode: .number)
    }

    private func buildGridKeyboard(mode: KeyboardMode) {
        let mainStack = pinnedVerticalStack(spacing: 7)
        addTopArea(to: mainStack)

        let leftColumn = makeColumn()
        leftColumn.addArrangedSubview(makeButton(for: .numberSwitch))
        leftColumn.addArrangedSubview(makeButton(for: .cursorLeft))
        leftColumn.addArrangedSubview(makeEmojiButton())
        leftColumn.addArrangedSubview(makeButton(for: .modeSwitch))

        let inputKeys = makeColumn()
        switch mode {
        case .zhuyin:
            for rowIndex in 0..<3 {
                let row = makeRow()
                for mapping in ZhuyinLayout.groups[(rowIndex * 3)..<(rowIndex * 3 + 3)] {
                    row.addArrangedSubview(makeZhuyinControl(mapping))
                }
                inputKeys.addArrangedSubview(row)
            }
        case .number:
            for row in NumberLayout.rows {
                let rowStack = makeRow()
                row.forEach { rowStack.addArrangedSubview(makeDigitControl($0)) }
                inputKeys.addArrangedSubview(rowStack)
            }
        case .abc:
            for (rowIndex, mappings) in ABCFlickLayout.letterRows.enumerated() {
                let row = makeRow()
                if rowIndex == 0 {
                    row.addArrangedSubview(makeSymbolControl(ABCFlickLayout.symbols))
                }
                mappings.forEach { row.addArrangedSubview(makeLetterControl($0)) }
                inputKeys.addArrangedSubview(row)
            }
        }
        let toneRow = makeRow()
        toneRow.addArrangedSubview(makeToneControl())
        if mode == .number {
            toneRow.addArrangedSubview(makeDigitControl(NumberLayout.zero))
        } else if mode == .abc {
            toneRow.addArrangedSubview(makeButton(for: .shift))
        } else {
            toneRow.addArrangedSubview(makeZhuyinControl(ZhuyinLayout.nasalFinals))
        }
        let punctuationButton = makePunctuationControl()
        toneRow.addArrangedSubview(punctuationButton)
        self.punctuationButton = punctuationButton
        inputKeys.addArrangedSubview(toneRow)

        let editKeys = makeColumn()
        editKeys.addArrangedSubview(makeButton(for: .delete))
        editKeys.addArrangedSubview(makeButton(for: .cursorRight))

        let rightColumn = makeColumn()
        rightColumn.addArrangedSubview(editKeys)
        rightColumn.addArrangedSubview(makeButton(for: .return))

        let grid = UIStackView()
        grid.axis = .horizontal
        grid.spacing = 7
        grid.addArrangedSubview(leftColumn)
        grid.addArrangedSubview(inputKeys)
        grid.addArrangedSubview(rightColumn)
        keyGrid = grid
        keyArea = grid

        NSLayoutConstraint.activate([
            rightColumn.widthAnchor.constraint(equalTo: leftColumn.widthAnchor),
            inputKeys.widthAnchor.constraint(
                equalTo: leftColumn.widthAnchor,
                multiplier: 3,
                constant: grid.spacing * 2
            )
        ])

        mainStack.addArrangedSubview(grid)

        let expandedCandidates = ExpandedCandidateView()
        expandedCandidates.onSelect = { [weak self] candidate in self?.select(candidate) }
        expandedCandidates.isHidden = true
        expandedCandidates.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(expandedCandidates)
        NSLayoutConstraint.activate([
            expandedCandidates.leadingAnchor.constraint(equalTo: grid.leadingAnchor),
            expandedCandidates.trailingAnchor.constraint(equalTo: grid.trailingAnchor),
            expandedCandidates.topAnchor.constraint(equalTo: grid.topAnchor),
            expandedCandidates.bottomAnchor.constraint(equalTo: grid.bottomAnchor)
        ])
        expandedCandidatesView = expandedCandidates
    }

    private func makeEmojiButton() -> KeyboardButton {
        let button = KeyboardButton(type: .system)
        button.setImage(keyIcon(named: "face.smiling"), for: .normal)
        button.tintColor = .label
        button.normalColor = KeyboardButton.standardKeyColor
        button.accessibilityLabel = "繪文字"
        button.addAction(UIAction { [weak self] _ in self?.showEmojiPanel() }, for: .touchUpInside)
        return button
    }

    private func showEmojiPanel() {
        if isSearchingEmoji {
            closeEmojiSearch()
            return
        }
        apply(engine.commitComposition())
        rememberCommittedSelection()
        coordinator?.invalidate()
        expectedSuggestionContext = nil
        isShowingEmojiPanel = true
        updateKeyboardHeight()
        rebuildKeyboard()
    }

    private func hideEmojiPanel() {
        isShowingEmojiPanel = false
        updateKeyboardHeight()
        rebuildKeyboard()
    }

    private static let emojiSearchFieldHeight: CGFloat = 36
    private static let emojiLogger = Logger(subsystem: "com.wirelesseye.FlickBo", category: "Emoji")

    private func loadedEmojiCatalog() -> EmojiCatalog? {
        if emojiCatalog == nil {
            do {
                emojiCatalog = try EmojiCatalog(bundle: .main)
            } catch {
                Self.emojiLogger.error("emoji catalog unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        return emojiCatalog
    }

    private func openEmojiSearch() {
        emojiSearchQuery.clear()
        isShowingEmojiPanel = false
        isSearchingEmoji = true
        updateKeyboardHeight()
        rebuildKeyboard()
    }

    /// Back to the palette. The query and any composition are dropped; they
    /// never reached the document.
    private func closeEmojiSearch() {
        apply(engine.resetComposition())
        coordinator?.invalidate()
        emojiSearchQuery.clear()
        isSearchingEmoji = false
        isShowingEmojiPanel = true
        updateKeyboardHeight()
        rebuildKeyboard()
    }

    private func clearEmojiSearch() {
        apply(engine.resetComposition())
        emojiSearchQuery.clear()
        refreshUI()
    }

    private func insertSearchedEmoji(_ emoji: String) {
        recentEmoji.record(emoji)
        textDocumentProxy.insertText(emoji)
    }

    private func refreshEmojiSearch() {
        guard isSearchingEmoji else { return }
        emojiSearchField?.update(committed: emojiSearchQuery.committedText, marked: emojiSearchQuery.markedText)
        let query = emojiSearchQuery.committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let results: [String]
        if let lastEmojiSearch, lastEmojiSearch.query == query {
            results = lastEmojiSearch.results
        } else {
            results = searchEmoji(query)
            lastEmojiSearch = (query, results)
        }
        emojiSearchResults?.update(results: results, hasQuery: !query.isEmpty)
    }

    /// Searches the query as typed and in canonical forms, since the words
    /// use OpenCC standard Traditional while candidates follow the chosen variant.
    private func searchEmoji(_ query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        if emojiSearchIndex == nil, let catalog = loadedEmojiCatalog() {
            do {
                var keywords: EmojiKeywordTable?
                do {
                    keywords = try EmojiKeywordTable(bundle: .main)
                } catch {
                    Self.emojiLogger.error("emoji keywords unavailable: \(String(describing: error), privacy: .public)")
                }
                emojiSearchIndex = EmojiSearchIndex(
                    table: try EmojiTable(bundle: .main),
                    catalog: catalog,
                    keywords: keywords
                )
            } catch {
                Self.emojiLogger.error("emoji words unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        guard let index = emojiSearchIndex else { return [] }
        let canonical = emojiSearchTextConverter().canonical(query)
        guard canonical != query else { return index.search(query) }
        var seen = Set<String>()
        return (index.search(canonical) + index.search(query)).filter { seen.insert($0).inserted }
    }

    private func emojiSearchTextConverter() -> CandidateTextConverter {
        if let emojiSearchConverter, emojiSearchConverter.variant == characterVariant {
            return emojiSearchConverter.converter
        }
        let converter = (try? CandidateTextConverter(
            variant: characterVariant,
            store: MappedOpenCCStore(bundle: .main)
        )) ?? .identity
        emojiSearchConverter = (characterVariant, converter)
        return converter
    }

    private func buildEmojiPanel() {
        // Recent items are read when the palette opens, so picks do not reorder it while open.
        let deleteButton = makeButton(for: .delete)
        deleteButton.normalColor = .clear
        let savedKind = UserDefaults.standard.string(forKey: Self.paletteKindKey).flatMap(PaletteKind.init(rawValue:))
        let panel = EmojiPanelView(
            pages: palettePages(),
            kind: savedKind ?? .emoji,
            backTitle: emojiPanelBackTitle,
            deleteButton: deleteButton
        )
        panel.onSelect = { [weak self] kind, item in
            guard let self else { return }
            recentStore(for: kind).record(item)
            handle(.symbol(item))
        }
        panel.onKindChange = { kind in
            UserDefaults.standard.set(kind.rawValue, forKey: Self.paletteKindKey)
        }
        panel.onBack = { [weak self] in self?.hideEmojiPanel() }
        panel.onSearch = { [weak self] in self?.openEmojiSearch() }
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            panel.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
    }

    private func recentStore(for kind: PaletteKind) -> RecentEmojiStore {
        switch kind {
        case .emoji: recentEmoji
        case .symbol: recentSymbols
        case .kaomoji: recentKaomoji
        }
    }

    private func loadedSymbolPalettes() -> SymbolPalettes? {
        if symbolPalettes == nil {
            do {
                symbolPalettes = try SymbolPalettes(bundle: .main)
            } catch {
                Self.emojiLogger.error("symbol palettes unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        return symbolPalettes
    }

    private func palettePages() -> [PaletteKind: PalettePage] {
        func recentSection(_ kind: PaletteKind) -> [PalettePage.Section] {
            let items = recentStore(for: kind).emoji
            return items.isEmpty ? [] : [PalettePage.Section(title: "最近使用", tab: .image("clock"), items: items)]
        }
        var pages: [PaletteKind: PalettePage] = [:]
        let emoji = (loadedEmojiCatalog()?.sections ?? []).map { section in
            PalettePage.Section(
                title: section.category.title,
                tab: .image(section.category.systemImage),
                items: section.entries.map(\.emoji)
            )
        }
        pages[.emoji] = PalettePage(sections: recentSection(.emoji) + emoji, columns: 8, fontSize: 30)
        if let palettes = loadedSymbolPalettes() {
            let symbols = palettes.symbols.map { section in
                PalettePage.Section(
                    title: section.category.title,
                    tab: .text(Self.paletteTab(for: section.category)),
                    items: section.items
                )
            }
            pages[.symbol] = PalettePage(sections: recentSection(.symbol) + symbols, columns: 8, fontSize: 24)
            let kaomoji = palettes.kaomoji.map { section in
                PalettePage.Section(
                    title: section.category.title,
                    tab: .text(Self.paletteTab(for: section.category)),
                    items: section.items
                )
            }
            pages[.kaomoji] = PalettePage(
                sections: recentSection(.kaomoji) + kaomoji,
                columns: 3,
                rowHeight: 44,
                fontSize: 16
            )
        }
        return pages
    }

    private static func paletteTab(for category: SymbolCategory) -> String {
        switch category {
        case .recent: "↺"
        case .punctuation: "，。"
        case .shapes: "☆♪"
        case .arrows: "→"
        case .math: "±"
        case .numbers: "①"
        case .units: "℃"
        case .letters: "ㄅα"
        }
    }

    private static func paletteTab(for category: KaomojiCategory) -> String {
        switch category {
        case .recent: "↺"
        case .smile: "^^"
        case .sweat: "^^;"
        case .surprise: "@_@"
        case .sadness: "T_T"
        case .displeasure: "-_-"
        }
    }

    private var emojiPanelBackTitle: String {
        switch engine.mode {
        case .zhuyin: "中"
        case .number: "123"
        case .abc: "ABC"
        }
    }

    private func makeToneControl() -> FlickKeyButton {
        let button = makeFlickButton(mapping: FlickKeyMapping(["space"])) { [weak self] direction in
            guard let self else { return }
            if self.engine.hasActiveTokens {
                guard let tone = ZhuyinLayout.tone(for: direction) else { return }
                self.handle(.tone(tone))
            } else {
                guard direction == .center else { return }
                self.handle(.space)
            }
        }
        button.titleLabel?.font = .systemFont(ofSize: 15)
        button.normalColor = KeyboardButton.standardKeyColor
        button.accessibilityLabel = "空白或音調"
        installSpaceCursorDrag(on: button)
        toneButton = button
        return button
    }

    /// Long-pressing the space bar turns it into a trackpad: sliding left or right moves
    /// the cursor, and releasing inserts no space. Disabled while the key enters tones.
    private func installSpaceCursorDrag(on button: UIView) {
        let recognizer = UILongPressGestureRecognizer(
            target: self,
            action: #selector(handleSpaceCursorDrag(_:))
        )
        recognizer.minimumPressDuration = 0.4
        recognizer.delegate = self
        button.addGestureRecognizer(recognizer)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UILongPressGestureRecognizer else { return true }
        return !engine.hasActiveTokens
    }

    @objc private func handleSpaceCursorDrag(_ recognizer: UILongPressGestureRecognizer) {
        let x = recognizer.location(in: view).x
        switch recognizer.state {
        case .began:
            cursorDragAnchorX = x
            KeyHaptics.selectionChanged()
            setCursorDragActive(true)
        case .changed:
            guard let anchor = cursorDragAnchorX else { return }
            let steps = Int((x - anchor) / Self.cursorStepWidth)
            guard steps != 0 else { return }
            cursorDragAnchorX = anchor + CGFloat(steps) * Self.cursorStepWidth
            let key: KeyboardKey = steps < 0 ? .cursorLeft : .cursorRight
            for _ in 0..<abs(steps) {
                handle(key)
            }
            KeyHaptics.selectionChanged()
        default:
            cursorDragAnchorX = nil
            setCursorDragActive(false)
        }
    }

    private func setCursorDragActive(_ active: Bool) {
        UIView.animate(withDuration: 0.15) {
            self.keyArea?.alpha = active ? 0.45 : 1
        }
    }

    private func makeZhuyinControl(_ mapping: FlickKeyMapping) -> FlickKeyButton {
        let button = makeFlickButton(mapping: mapping) { [weak self] direction in
            guard let symbol = mapping[direction], let character = symbol.first else { return }
            self?.handle(.zhuyin(character))
        }
        if showsDirectionalSymbols {
            button.directionalFaceStyle = .zhuyin
            button.directionalFace = mapping
        }
        return button
    }

    private func makeDigitControl(_ digit: Character) -> FlickKeyButton {
        let mapping = NumberLayout.mapping(for: digit, width: engine.characterWidth)
        let button = makeFlickButton(mapping: mapping) { [weak self] direction in
            guard let self else { return }
            if direction == .center {
                self.handle(.digit(digit))
            } else if let symbol = mapping[direction] {
                self.handle(.symbol(symbol))
            }
        }
        if showsDirectionalSymbols {
            button.directionalFaceStyle = .digit
            button.directionalFace = mapping
        } else {
            button.titleLabel?.font = .systemFont(ofSize: 24, weight: .regular)
        }
        button.accessibilityLabel = mappingSymbols(mapping)
        return button
    }

    private func makeLetterControl(_ base: FlickKeyMapping) -> FlickKeyButton {
        let button = makeFlickButton(mapping: base) { [weak self] direction in
            guard let symbol = base[direction], let character = symbol.first else { return }
            self?.handle(.letter(character))
        }
        button.directionalFaceStyle = .zhuyin
        button.accessibilityLabel = mappingSymbols(base)
        letterKeys.append((base, button))
        return button
    }

    private func makeSymbolControl(_ base: FlickKeyMapping) -> FlickKeyButton {
        let mapping = base.map(engine.characterWidth.apply(to:))
        let button = makeFlickButton(mapping: mapping) { [weak self] direction in
            guard let symbol = mapping[direction] else { return }
            self?.handle(.symbol(symbol))
        }
        if showsDirectionalSymbols {
            button.directionalFaceStyle = .punctuation
            button.directionalFace = mapping
        }
        button.accessibilityLabel = mappingSymbols(mapping)
        return button
    }

    private func refreshLetterKeys() {
        for (base, button) in letterKeys {
            let mapping = ABCFlickLayout.letters(
                base,
                letterCase: engine.letterCase,
                width: engine.characterWidth
            )
            guard button.mapping != mapping || (button.directionalFace != nil) != showsDirectionalSymbols
            else { continue }
            button.mapping = mapping
            button.directionalFace = showsDirectionalSymbols ? mapping : nil
        }
    }

    private var currentPunctuation: FlickKeyMapping {
        ZhuyinLayout.punctuation(width: engine.characterWidth)
    }

    private func makePunctuationControl() -> FlickKeyButton {
        let mapping = currentPunctuation
        let button = makeFlickButton(mapping: mapping) { [weak self] direction in
            guard let self else { return }
            if self.engine.hasActiveTokens {
                guard direction == .center else { return }
                self.handle(.tone(.neutral))
            } else {
                guard let symbol = self.currentPunctuation[direction] else { return }
                self.handle(.symbol(symbol))
            }
        }
        applyPunctuationFace(button, mapping: mapping)
        button.accessibilityLabel = mappingSymbols(mapping)
        return button
    }

    private func applyPunctuationFace(_ button: FlickKeyButton, mapping: FlickKeyMapping) {
        guard !showsDirectionalSymbols else {
            button.directionalFace = mapping
            return
        }
        button.directionalFace = nil
        button.setAttributedTitle(
            NSAttributedString(
                string: mapping.center,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 18),
                    .foregroundColor: UIColor.label
                ]
            ),
            for: .normal
        )
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
    }

    private func mappingSymbols(_ mapping: FlickKeyMapping) -> String {
        FlickDirection.allCases.compactMap { mapping[$0] }.joined()
    }

    private func characterWidth(for mode: KeyboardMode) -> CharacterWidth {
        if let width = characterWidths[mode] { return width }
        let width: CharacterWidth = KeyboardSettings.usesFullWidth(inMode: settingsName(for: mode))
            ? .full
            : .half
        characterWidths[mode] = width
        return width
    }

    private func settingsName(for mode: KeyboardMode) -> String {
        switch mode {
        case .zhuyin: "zhuyin"
        case .number: "number"
        case .abc: "abc"
        }
    }

    /// The toolbar only shows without input, so nothing is being composed.
    private func selectCharacterVariant(_ variant: CharacterVariant) {
        guard variant != characterVariant else { return }
        characterVariant = variant
        KeyboardSettings.characterVariant = variant
        settingsCharacterVariant = KeyboardSettings.characterVariant
        candidateBar?.characterVariant = variant
        resetCoordinator()
        refreshCandidates()
    }

    private func resetCoordinator() {
        coordinator?.invalidate()
        coordinator = nil
        coordinatorHasFullAccess = nil
        coordinatorCharacterVariant = nil
        coordinatorShowsEmoji = nil
    }

    private func toggleCharacterWidth() {
        let mode = engine.mode
        let width = characterWidth(for: mode).toggled
        characterWidths[mode] = width
        KeyboardSettings.setUsesFullWidth(width == .full, inMode: settingsName(for: mode))
        engine.clearSymbolCandidates()
        rebuildKeyboard()
    }

    private func pinnedVerticalStack(spacing: CGFloat) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
        return stack
    }

    private func makeRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 7
        stack.distribution = .fillEqually
        return stack
    }

    private func makeColumn() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 7
        stack.distribution = .fillEqually
        return stack
    }

    private func makeControlRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 7
        stack.distribution = .fill
        return stack
    }

    private func makeFlickButton(
        mapping: FlickKeyMapping,
        onSelection: @escaping (FlickDirection) -> Void
    ) -> FlickKeyButton {
        let button = FlickKeyButton(mapping: mapping)
        button.overlayHost = view
        button.onSelection = onSelection
        button.normalColor = KeyboardButton.standardKeyColor
        button.accessibilityLabel = mapping.center
        return button
    }

    private func makeButton(for key: KeyboardKey) -> KeyboardButton {
        let button = KeyboardButton(type: .system)
        button.accessibilityLabel = accessibilityLabel(for: key)
        button.normalColor = KeyboardButton.standardKeyColor

        switch key {
        case .letter, .digit:
            button.titleLabel?.font = .systemFont(ofSize: 24, weight: .regular)
        default:
            break
        }

        if key == .nextKeyboard {
            button.setImage(UIImage(systemName: "globe"), for: .normal)
            button.addAction(
                UIAction { [weak self] _ in self?.prepareForInputModeSwitch() },
                for: .touchUpInside
            )
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            nextKeyboardButton = button
        } else if key == .delete || key == .cursorLeft || key == .cursorRight {
            installKeyRepeat(for: key, on: button)
        } else {
            button.addAction(UIAction { [weak self] _ in self?.handle(key) }, for: .touchUpInside)
            if key == .space {
                installSpaceCursorDrag(on: button)
            }
        }
        keyButtons.append((key, button))
        return button
    }

    private func installKeyRepeat(for key: KeyboardKey, on button: KeyboardButton) {
        let repeater = KeyRepeater { [weak self] in self?.handle(key) }
        button.addAction(UIAction { _ in repeater.begin() }, for: .touchDown)
        button.addAction(
            UIAction { _ in repeater.end() },
            for: [.touchUpOutside, .touchCancel, .touchDragExit]
        )
        button.addAction(UIAction { [weak self] _ in
            let didRepeat = repeater.consumeRepeat()
            repeater.end()
            guard !didRepeat else { return }
            self?.handle(key)
        }, for: .touchUpInside)
    }

    /// Keyboard extensions can't call `UIApplication.shared`, so walk the responder chain to the
    /// host application and invoke `openURL:options:completionHandler:` dynamically.
    private func openContainingApp() {
        guard let url = URL(string: "flickbo://settings") else { return }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.isKind(of: NSClassFromString("UIApplication") ?? NSNull.self),
               current.responds(to: selector),
               let method = current.method(for: selector) {
                typealias OpenURL = @convention(c) (
                    AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
                ) -> Void
                unsafeBitCast(method, to: OpenURL.self)(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }

    private func prepareForInputModeSwitch() {
        apply(engine.update(for: .nextKeyboard))
        rememberCommittedSelection()
        refreshUI()
    }

    private func handle(_ key: KeyboardKey) {
        if isSearchingEmoji, key == .return, engine.composition.isEmpty {
            closeEmojiSearch()
            return
        }
        let oldMode = engine.mode
        let update = engine.update(for: key)
        apply(update)
        rememberCommittedSelection()
        if key == .return, oldMode == .zhuyin,
           case let .insertText(text)? = update.documentEffects.first,
           update.invalidatesCandidates {
            requestPostCommitSuggestions(for: text)
        }
        if engine.mode != oldMode {
            coordinator?.invalidate()
            expectedSuggestionContext = nil
            rebuildKeyboard()
        } else {
            refreshUI()
        }
    }

    private func select(_ item: CandidateItem) {
        setCandidateListExpanded(false)
        switch item {
        case let .input(candidate):
            let update = engine.selectCandidate(
                candidate,
                autoCommit: KeyboardSettings.autoCommitComposition
            )
            apply(update)
            rememberCommittedSelection()
            if case let .insertText(text)? = update.documentEffects.first,
               update.invalidatesCandidates {
                requestPostCommitSuggestions(for: text)
            }
        case let .suggestion(text):
            let update = engine.selectSuggestion(text)
            guard !update.documentEffects.isEmpty else { return }
            apply(update)
            requestPostCommitSuggestions(for: text)
        case let .symbol(text):
            // Only replace when the inserted symbol is still right before the cursor.
            if let original = engine.lastInsertedSymbol,
               let before = contextBeforeInput,
               !before.hasSuffix(original) {
                engine.clearSymbolCandidates()
            } else {
                apply(engine.selectSymbolCandidate(text))
            }
        }
        refreshUI()
    }

    private func requestPostCommitSuggestions(for text: String) {
        guard engine.mode == .zhuyin, !isSearchingEmoji else { return }
        let context = GrammarContext.tail(of: documentContextBeforeComposition + text)
        expectedSuggestionContext = context
        resolvedCoordinator().requestSuggestions(after: context)
    }

    private func rememberCommittedSelection() {
        // Search queries are not learned as the user's writing.
        guard hasFullAccess, KeyboardSettings.remembersSelections, !isSearchingEmoji,
              !engine.lastCommittedChunks.isEmpty
        else { return }
        resolvedCoordinator().recordCommittedSelection(
            chunks: engine.lastCommittedChunks,
            fullySelected: engine.lastCommitWasFullySelected
        )
    }

    private func toggleCandidateExpansion() {
        setCandidateListExpanded(!isCandidateListExpanded)
    }

    private func setCandidateListExpanded(_ expanded: Bool) {
        guard isCandidateListExpanded != expanded else { return }
        isCandidateListExpanded = expanded
        expandedCandidatesView?.isHidden = !expanded
        keyGrid?.isUserInteractionEnabled = !expanded
        keyGrid?.accessibilityElementsHidden = expanded
        if expanded {
            refreshExpandedCandidates()
            view.layoutIfNeeded()
            expandedCandidatesView?.prepareForEntrance()
            candidateBar?.setExpanded(true)
            expandedCandidatesView?.animateEntrance()
        } else {
            expandedCandidatesView?.resetEntranceState()
            candidateBar?.setExpanded(false)
        }
        UIView.animate(withDuration: CandidateBarView.animationDuration) {
            self.keyGrid?.alpha = expanded ? 0 : 1
        }
        view.setNeedsLayout()
    }

    private func apply(_ update: KeyboardUpdate) {
        documentEffectDepth += 1
        defer { documentEffectDepth -= 1 }
        if !documentHasMarkedText {
            // Read before marked text is inserted, so it holds only committed text.
            documentContextBeforeComposition = GrammarContext.tail(of: contextBeforeInput)
        }
        (isSearchingEmoji ? searchEffectApplier : effectApplier).apply(update.documentEffects)
        documentHasMarkedText = engine.hasMarkedText
        if update.invalidatesCandidates {
            coordinator?.invalidate()
            expectedSuggestionContext = nil
        } else if update.candidateRequest == nil,
                  !engine.hasMarkedText,
                  !update.documentEffects.isEmpty {
            coordinator?.invalidate()
            expectedSuggestionContext = nil
        }
        if let request = update.candidateRequest {
            expectedSuggestionContext = nil
            let precedingText = request.continuesDocument
                ? documentContextBeforeComposition + request.precedingText
                : request.precedingText
            resolvedCoordinator().requestCandidates(
                for: request.tokens,
                precedingText: GrammarContext.tail(of: precedingText)
            )
        }
    }

    /// Text before the cursor where effects go: the search query while searching emoji.
    private var contextBeforeInput: String? {
        isSearchingEmoji ? emojiSearchQuery.committedText : textDocumentProxy.documentContextBeforeInput
    }

    private func handleHostDocumentChange() {
        // While searching, the host only changes by inserted emoji.
        guard documentEffectDepth == 0, !isSearchingEmoji else { return }
        if let symbol = engine.lastInsertedSymbol {
            // Host callbacks can arrive after our own insertion; keep variants while
            // the inserted symbol still sits right before the cursor.
            if textDocumentProxy.documentContextBeforeInput?.hasSuffix(symbol) ?? true { return }
            engine.clearSymbolCandidates()
            refreshCandidates()
        }
        if engine.composition.isEmpty {
            if let expectedSuggestionContext,
               GrammarContext.tail(of: textDocumentProxy.documentContextBeforeInput)
                == expectedSuggestionContext {
                return
            }
            coordinator?.invalidate()
            expectedSuggestionContext = nil
        } else {
            resetComposition()
        }
    }

    private func resetComposition() {
        apply(engine.resetComposition())
        refreshUI()
    }

    private var candidateItems: [CandidateItem] {
        let symbols = engine.symbolCandidates
        guard symbols.isEmpty else { return symbols.map(CandidateItem.symbol) }
        let items = coordinator?.items ?? []
        guard isSearchingEmoji else { return items }
        // Search results already show emoji; candidates only build the query.
        return items.filter { item in
            if case let .input(candidate) = item { return !candidate.isEmoji }
            return true
        }
    }

    private func refreshCandidates() {
        let candidates = candidateItems
        candidateBar?.update(with: candidates)
        if isSearchingEmoji {
            candidateBar?.isHidden = candidates.isEmpty
            // The candidate bar is translucent, so the results must not show through.
            emojiSearchResults?.isHidden = !candidates.isEmpty
        }
        refreshExpandedCandidates()
        if candidates.isEmpty {
            setCandidateListExpanded(false)
        }
    }

    private func refreshExpandedCandidates() {
        guard isCandidateListExpanded else { return }
        let candidates = candidateItems
        let visibleCount = candidateBar?.visibleCandidateCount ?? 0
        let start = min(visibleCount, candidates.count)
        expandedCandidatesView?.update(with: Array(candidates.dropFirst(start)))
    }

    private func resolvedCoordinator() -> ChineseInputCoordinator {
        if let coordinator {
            return coordinator
        }
        let fullAccess = hasFullAccess
        let characterVariant = self.characterVariant
        let showsEmoji = KeyboardSettings.showsEmojiCandidates
        let coordinator = ChineseInputCoordinator { [bundle = Bundle.main] in
            let userStore = KeyboardSettings.userLearningURL.flatMap {
                try? UserLearningStore(url: $0, writable: fullAccess)
            }
            return try LexiconChineseInputPipeline(
                bundle: bundle,
                decoder: Decoder(
                    configuration: DecoderConfiguration(
                        maximumCandidates: Self.maximumCandidateCount
                    )
                ),
                userLearningStore: userStore,
                characterVariant: characterVariant,
                includesEmoji: showsEmoji
            )
        }
        coordinator.onChange = { [weak self] in self?.refreshCandidates() }
        self.coordinator = coordinator
        coordinatorHasFullAccess = fullAccess
        coordinatorCharacterVariant = characterVariant
        coordinatorShowsEmoji = showsEmoji
        return coordinator
    }

    private func refreshUI() {
        refreshLetterKeys()
        refreshCandidates()
        refreshEmojiSearch()
        let hasPending = engine.hasActiveTokens
        if hasPending {
            punctuationButton?.mapping = FlickKeyMapping([MandarinTone.neutral.symbol])
            punctuationButton?.directionalFace = nil
            punctuationButton?.showsPreview = false
            punctuationButton?.setAttributedTitle(
                ToneSymbolStyle.attributedText(
                    for: MandarinTone.neutral.symbol,
                    fontSize: ToneSymbolStyle.keyFontSize
                ),
                for: .normal
            )
            punctuationButton?.accessibilityLabel = "輕聲"
        } else {
            let punctuation = currentPunctuation
            punctuationButton?.mapping = punctuation
            if let punctuationButton {
                applyPunctuationFace(punctuationButton, mapping: punctuation)
            }
            punctuationButton?.showsPreview = true
            punctuationButton?.accessibilityLabel = mappingSymbols(punctuation)
        }
        toneButton?.mapping = hasPending
            ? ZhuyinLayout.tones
            : FlickKeyMapping(["space"])
        toneButton?.showsPreview = hasPending
        if hasPending {
            toneButton?.setImage(nil, for: .normal)
            if showsDirectionalSymbols {
                toneButton?.directionalFaceStyle = .tone
                toneButton?.directionalFace = ZhuyinLayout.tones
            } else {
                toneButton?.directionalFace = nil
                toneButton?.setAttributedTitle(
                    ToneSymbolStyle.attributedText(
                        for: MandarinTone.first.symbol,
                        fontSize: ToneSymbolStyle.keyFontSize
                    ),
                    for: .normal
                )
            }
        } else {
            toneButton?.directionalFace = nil
            toneButton?.setAttributedTitle(nil, for: .normal)
            toneButton?.setTitle(nil, for: .normal)
            toneButton?.setImage(keyIcon(named: "space"), for: .normal)
            toneButton?.tintColor = .label
        }

        UIView.performWithoutAnimation {
            for (key, button) in keyButtons {
                switch key {
                case let .letter(character):
                    let title = engine.characterWidth.apply(to: engine.letterCase == .lowercase
                        ? String(character).lowercased()
                        : String(character).uppercased())
                    button.setTitle(title, for: .normal)
                case let .digit(character):
                    button.setTitle(String(character), for: .normal)
                case .shift:
                    let symbol: String
                    switch engine.letterCase {
                    case .lowercase: symbol = "shift"
                    case .shifted: symbol = "shift.fill"
                    case .capsLocked: symbol = "capslock.fill"
                    }
                    button.setTitle(nil, for: .normal)
                    button.setImage(keyIcon(named: symbol), for: .normal)
                    button.tintColor = .label
                case .delete:
                    button.setTitle(nil, for: .normal)
                    button.setImage(keyIcon(named: "delete.left"), for: .normal)
                    button.tintColor = .label
                case .cursorLeft, .cursorRight:
                    button.setTitle(nil, for: .normal)
                    let symbol = key == .cursorLeft ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill"
                    button.setImage(keyIcon(named: symbol, pointSize: 12), for: .normal)
                    button.tintColor = .label
                case .space:
                    button.setTitle(nil, for: .normal)
                    button.setImage(nil, for: .normal)
                case .return:
                    updateReturnKeyFace(button)
                case .modeSwitch:
                    button.setTitle(engine.mode == .abc ? "中" : "ABC", for: .normal)
                    button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
                case .numberSwitch:
                    button.setTitle(engine.mode == .number ? "中" : "123", for: .normal)
                    button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
                case let .tone(tone):
                    button.setAttributedTitle(
                        ToneSymbolStyle.attributedText(
                            for: tone.symbol,
                            fontSize: ToneSymbolStyle.keyFontSize
                        ),
                        for: .normal
                    )
                case .nextKeyboard, .zhuyin, .symbol:
                    break
                }
            }
            view.layoutIfNeeded()
        }
    }

    private func configureHeight() {
        let constraint = view.heightAnchor.constraint(equalToConstant: 260)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        heightConstraint = constraint
    }

    private func updateKeyboardHeight() {
        let compact = traitCollection.verticalSizeClass == .compact
        // The emoji palette is taller so more rows of emoji fit; search adds its field.
        let extra: CGFloat
        if isShowingEmojiPanel {
            extra = compact ? 20 : 50
        } else if isSearchingEmoji {
            extra = Self.emojiSearchFieldHeight + 7
        } else {
            extra = 0
        }
        heightConstraint?.constant = (compact ? 220 : 280) + extra
    }

    private func refreshReturnKeyFace() {
        for (key, button) in keyButtons where key == .return {
            updateReturnKeyFace(button)
        }
    }

    private func updateReturnKeyFace(_ button: KeyboardButton) {
        let type = textDocumentProxy.returnKeyType
        if engine.mode == .zhuyin, engine.hasMarkedText {
            setReturnTitle("確定", on: button)
            applyReturnKeyAccent(false, on: button)
            return
        }
        if isSearchingEmoji {
            setReturnTitle("完成", on: button)
            applyReturnKeyAccent(false, on: button)
            return
        }
        if let iconName = returnKeyIconName(for: type) {
            setReturnIcon(iconName, on: button)
        } else if let title = returnKeyTitle(for: type) {
            setReturnTitle(title, on: button)
        } else {
            setReturnIcon("arrow.turn.down.left", on: button)
        }
        applyReturnKeyAccent(type != nil && type != .default, on: button)
    }

    private func applyReturnKeyAccent(_ isAccented: Bool, on button: KeyboardButton) {
        button.normalColor = isAccented ? .systemBlue : KeyboardButton.standardKeyColor
        let foreground: UIColor = isAccented ? .white : .label
        button.setTitleColor(foreground, for: .normal)
        button.tintColor = foreground
    }

    private func setReturnIcon(_ name: String, on button: KeyboardButton) {
        button.setTitle(nil, for: .normal)
        button.setImage(keyIcon(named: name), for: .normal)
        button.tintColor = .label
    }

    private func setReturnTitle(_ title: String, on button: KeyboardButton) {
        button.setImage(nil, for: .normal)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
    }

    private func returnKeyIconName(for type: UIReturnKeyType?) -> String? {
        switch type {
        case .default: "arrow.turn.down.left"
        case .go: "arrow.forward"
        case .next, .continue: "chevron.forward"
        case .route: "arrow.triangle.turn.up.right.diamond"
        case .search: "magnifyingglass"
        case .send: "paperplane.fill"
        case .done: "checkmark"
        case .emergencyCall: "phone.fill"
        default: nil
        }
    }

    private func returnKeyTitle(for type: UIReturnKeyType?) -> String? {
        switch type {
        case .join: "加入"
        case .google: "Google"
        case .yahoo: "Yahoo"
        default: nil
        }
    }

    private func keyIcon(named name: String, pointSize: CGFloat = 16) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return UIImage(systemName: name, withConfiguration: configuration)
    }

    private func accessibilityLabel(for key: KeyboardKey) -> String {
        switch key {
        case let .letter(character), let .zhuyin(character), let .digit(character):
            String(character)
        case let .symbol(text): text
        case let .tone(tone): tone == .first ? "第一聲" : tone.symbol
        case .shift: "Shift"
        case .delete: "Delete"
        case .cursorLeft: "向左移動"
        case .cursorRight: "向右移動"
        case .space: "Space"
        case .return: "Return"
        case .nextKeyboard: "Next keyboard"
        case .modeSwitch: engine.mode == .abc ? "切換中文" : "切換 ABC"
        case .numberSwitch: engine.mode == .number ? "切換中文" : "切換數字模式"
        }
    }
}
