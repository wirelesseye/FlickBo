import UIKit

/// The palettes the panel switches between from its top bar.
enum PaletteKind: String, CaseIterable {
    case emoji
    case symbol
    case kaomoji

    var title: String {
        switch self {
        case .emoji: "繪文字"
        case .symbol: "符號"
        case .kaomoji: "顏文字"
        }
    }
}

/// What one palette shows: its categories in order and how its grid is laid out.
struct PalettePage {
    enum Tab {
        /// An SF Symbol name.
        case image(String)
        case text(String)
    }

    struct Section {
        let title: String
        let tab: Tab
        let items: [String]
    }

    let sections: [Section]
    let columns: Int
    /// Row height; nil makes square cells.
    var rowHeight: CGFloat?
    let fontSize: CGFloat
}

/// Emoji, symbol and kaomoji palettes shown in place of the keys. The top bar
/// opens emoji search and switches palettes. The bottom bar returns to the
/// keys, jumps between the current palette's categories and deletes. The grid
/// scrolls through every category, and the bottom bar follows the category
/// being shown.
final class EmojiPanelView: UIView {
    enum Metrics {
        static let barHeight: CGFloat = 40
        static let headerHeight: CGFloat = 26
    }

    /// Shared with the search field so both magnifiers are the same size.
    static let searchSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12)

    var onSelect: ((PaletteKind, String) -> Void)?
    var onKindChange: ((PaletteKind) -> Void)?
    var onBack: (() -> Void)?
    var onSearch: (() -> Void)?

    private let pages: [PaletteKind: PalettePage]
    private(set) var kind: PaletteKind
    private var sections: [PalettePage.Section] = []
    private let layout = EmojiGridLayout()
    private let collectionView: UICollectionView
    private var kindButtons: [PaletteKind: UIButton] = [:]
    private let categoryStack = UIStackView()
    private var categoryButtons: [EmojiCategoryButton] = []
    private var selectedSection: Int?
    private var isScrollingToCategory = false

    /// `deleteButton` keeps the keyboard's own repeat behavior.
    init(pages: [PaletteKind: PalettePage], kind: PaletteKind, backTitle: String, deleteButton: UIView) {
        self.pages = pages
        self.kind = pages[kind] == nil ? .emoji : kind
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        buildViews(backTitle: backTitle, deleteButton: deleteButton)
        show(self.kind)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    private func buildViews(backTitle: String, deleteButton: UIView) {
        let topBar = makeTopBar()

        collectionView.backgroundColor = KeyboardSurface.interactionColor
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsVerticalScrollIndicator = false
        collectionView.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseIdentifier)
        collectionView.register(
            EmojiSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: EmojiSectionHeader.reuseIdentifier
        )

        let bottomBar = makeBottomBar(backTitle: backTitle, deleteButton: deleteButton)

        let stack = UIStackView(arrangedSubviews: [topBar, collectionView, bottomBar])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Metrics.barHeight),
            bottomBar.heightAnchor.constraint(equalToConstant: Metrics.barHeight)
        ])
    }

    private func makeTopBar() -> UIView {
        var searchConfiguration = UIButton.Configuration.filled()
        searchConfiguration.image = UIImage(systemName: "magnifyingglass")
        searchConfiguration.imagePadding = 6
        searchConfiguration.preferredSymbolConfigurationForImage = Self.searchSymbolConfiguration
        searchConfiguration.title = "搜尋繪文字"
        searchConfiguration.baseBackgroundColor = KeyboardButton.standardKeyColor
        searchConfiguration.baseForegroundColor = .secondaryLabel
        searchConfiguration.cornerStyle = .capsule
        searchConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        searchConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 15)
            return attributes
        }
        let search = UIButton(configuration: searchConfiguration)
        search.contentHorizontalAlignment = .leading
        search.accessibilityLabel = "搜尋繪文字"
        search.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)

        let kinds: [(kind: PaletteKind, title: String?, image: String?)] = [
            (.emoji, nil, "face.smiling"),
            (.symbol, "&%", nil),
            (.kaomoji, ":-)", nil),
        ]
        let buttons = kinds.map { item -> UIButton in
            var configuration = UIButton.Configuration.plain()
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = .label
            if let image = item.image {
                configuration.image = UIImage(
                    systemName: image,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                )
            }
            if let title = item.title {
                configuration.attributedTitle = AttributedString(
                    title,
                    attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)])
                )
            }
            let button = UIButton(configuration: configuration)
            button.isEnabled = pages[item.kind] != nil
            button.accessibilityLabel = item.kind.title
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.switchKind(to: item.kind) }, for: .touchUpInside)
            kindButtons[item.kind] = button
            return button
        }

        let bar = UIStackView(arrangedSubviews: [search] + buttons)
        bar.axis = .horizontal
        bar.spacing = 4
        bar.alignment = .fill
        return bar
    }

    private func makeBottomBar(backTitle: String, deleteButton: UIView) -> UIView {
        let back = UIButton(type: .system)
        back.setTitle(backTitle, for: .normal)
        back.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        back.titleLabel?.adjustsFontSizeToFitWidth = true
        back.tintColor = .label
        back.accessibilityLabel = "返回鍵盤"
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        back.widthAnchor.constraint(equalToConstant: 42).isActive = true

        categoryStack.axis = .horizontal
        categoryStack.distribution = .fillEqually

        deleteButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let bar = UIStackView(arrangedSubviews: [back, categoryStack, deleteButton])
        bar.axis = .horizontal
        bar.spacing = 4
        return bar
    }

    // MARK: - Palettes

    private func switchKind(to kind: PaletteKind) {
        guard kind != self.kind, pages[kind] != nil else { return }
        show(kind)
        onKindChange?(kind)
    }

    private func show(_ kind: PaletteKind) {
        guard let page = pages[kind] else { return }
        self.kind = kind
        sections = page.sections.filter { !$0.items.isEmpty }
        for (buttonKind, button) in kindButtons {
            let isCurrent = buttonKind == kind
            button.configuration?.background.backgroundColor = isCurrent ? KeyboardButton.standardKeyColor : .clear
            if isCurrent {
                button.accessibilityTraits.insert(.selected)
            } else {
                button.accessibilityTraits.remove(.selected)
            }
        }

        layout.columns = page.columns
        layout.rowHeight = page.rowHeight
        layout.invalidateLayout()
        collectionView.reloadData()
        // Lay out the new sections before scrolling: the scroll callback asks
        // for section headers, and the old layout would answer with sections
        // the new palette may not have.
        isScrollingToCategory = true
        collectionView.layoutIfNeeded()
        collectionView.setContentOffset(.zero, animated: false)
        isScrollingToCategory = false

        categoryButtons.forEach { $0.removeFromSuperview() }
        categoryButtons = sections.enumerated().map { index, section in
            let button = EmojiCategoryButton(type: .system)
            switch section.tab {
            case let .image(name):
                button.setImage(
                    UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)),
                    for: .normal
                )
            case let .text(text):
                button.setTitle(text, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
                button.titleLabel?.adjustsFontSizeToFitWidth = true
                button.titleLabel?.minimumScaleFactor = 0.6
            }
            button.tintColor = .secondaryLabel
            button.accessibilityLabel = section.title
            button.addAction(UIAction { [weak self] _ in self?.scroll(toSection: index) }, for: .touchUpInside)
            categoryStack.addArrangedSubview(button)
            return button
        }
        selectedSection = nil
        selectSection(sections.isEmpty ? nil : 0)
    }

    // MARK: - Categories

    private func selectSection(_ section: Int?) {
        guard section != selectedSection else { return }
        if let selectedSection, categoryButtons.indices.contains(selectedSection) {
            let button = categoryButtons[selectedSection]
            button.tintColor = .secondaryLabel
            button.isCurrent = false
            button.accessibilityTraits.remove(.selected)
        }
        selectedSection = section
        if let section, categoryButtons.indices.contains(section) {
            let button = categoryButtons[section]
            button.tintColor = .label
            button.isCurrent = true
            button.accessibilityTraits.insert(.selected)
        }
    }

    private func scroll(toSection section: Int) {
        guard sections.indices.contains(section) else { return }
        collectionView.layoutIfNeeded()
        guard section < collectionView.numberOfSections else { return }
        guard let header = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: IndexPath(item: 0, section: section)
        ) else { return }
        let maximumOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        selectSection(section)
        isScrollingToCategory = true
        collectionView.setContentOffset(CGPoint(x: 0, y: min(header.frame.minY, maximumOffset)), animated: false)
        isScrollingToCategory = false
    }

    /// The section whose content sits at the top of the visible grid.
    private func sectionAtTop() -> Int? {
        guard !sections.isEmpty else { return nil }
        let probe = collectionView.contentOffset.y + Metrics.headerHeight
        var current = 0
        for index in sections.indices where index < collectionView.numberOfSections {
            guard let header = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: index)
            ) else { continue }
            if header.frame.minY <= probe { current = index } else { break }
        }
        return current
    }
}

extension EmojiPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseIdentifier, for: indexPath)
        (cell as? EmojiCell)?.configure(
            with: sections[indexPath.section].items[indexPath.item],
            kind: kind,
            fontSize: pages[kind]?.fontSize ?? 30
        )
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: EmojiSectionHeader.reuseIdentifier,
            for: indexPath
        )
        (header as? EmojiSectionHeader)?.title = sections[indexPath.section].title
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        KeyHaptics.keyDown()
        onSelect?(kind, sections[indexPath.section].items[indexPath.item])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isScrollingToCategory else { return }
        selectSection(sectionAtTop())
    }
}

/// A flow layout with `columns` cells per row, sized from the grid's current
/// width: square, or `rowHeight` tall.
private final class EmojiGridLayout: UICollectionViewFlowLayout {
    var columns = 8
    var rowHeight: CGFloat?

    override init() {
        super.init()
        minimumInteritemSpacing = 0
        minimumLineSpacing = 0
        headerReferenceSize = CGSize(width: 0, height: EmojiPanelView.Metrics.headerHeight)
        sectionInset = UIEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepare() {
        if let width = collectionView?.bounds.width, width > 0 {
            // Rounded down, so a full row always fits.
            let side = floor(width / CGFloat(max(1, columns)))
            let size = CGSize(width: side, height: rowHeight ?? side)
            if itemSize != size {
                itemSize = size
            }
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }
}

private final class EmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        contentView.layer.cornerRadius = 8
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? KeyboardButton.standardKeyColor : .clear }
    }

    func configure(with item: String, kind: PaletteKind, fontSize: CGFloat) {
        // Spaces would draw nothing, so they are shown by name.
        if let name = Self.spaceName(item) {
            label.text = name
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabel
            accessibilityLabel = name
        } else {
            label.text = item
            label.font = .systemFont(ofSize: fontSize)
            label.textColor = .label
            accessibilityLabel = item
        }
        accessibilityIdentifier = "\(kind.rawValue)-\(item)"
    }

    private static func spaceName(_ item: String) -> String? {
        switch item {
        case " ": "空格"
        case "\u{3000}": "全形空格"
        default: nil
        }
    }
}

private final class EmojiSectionHeader: UICollectionReusableView {
    static let reuseIdentifier = "EmojiSectionHeader"

    private let label = UILabel()

    var title: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// A category tab that marks the current category with a translucent circle,
/// like the system emoji keyboard.
private final class EmojiCategoryButton: UIButton {
    static let indicatorDiameter: CGFloat = 32

    private let indicator = UIView()

    var isCurrent = false {
        didSet { indicator.isHidden = !isCurrent }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        indicator.isUserInteractionEnabled = false
        indicator.isHidden = true
        indicator.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.18)
                : UIColor(white: 0, alpha: 0.1)
        }
        insertSubview(indicator, at: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = min(Self.indicatorDiameter, bounds.height)
        indicator.frame = CGRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        indicator.layer.cornerRadius = diameter / 2
        sendSubviewToBack(indicator)
    }
}
