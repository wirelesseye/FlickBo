import UIKit

/// Emoji palette shown in place of the keys. The top bar holds emoji search
/// and the symbol kinds (emoji, symbols, kaomoji); only emoji work for now.
/// The bottom bar returns to the keys, jumps between emoji categories and
/// deletes. The grid scrolls through every category, and the bottom bar
/// follows the category being shown.
final class EmojiPanelView: UIView {
    enum Metrics {
        static let barHeight: CGFloat = 40
        static let columns = 8
        static let headerHeight: CGFloat = 26
        static let emojiFontSize: CGFloat = 30
    }

    var onSelect: ((String) -> Void)?
    var onBack: (() -> Void)?

    private let sections: [EmojiSection]
    private let collectionView: UICollectionView
    private var categoryButtons: [EmojiCategory: EmojiCategoryButton] = [:]
    private var selectedCategory: EmojiCategory?
    private var isScrollingToCategory = false

    /// `deleteButton` keeps the keyboard's own repeat behavior.
    init(sections: [EmojiSection], backTitle: String, deleteButton: UIView) {
        self.sections = sections.filter { !$0.entries.isEmpty }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: EmojiGridLayout())
        super.init(frame: .zero)
        buildViews(backTitle: backTitle, deleteButton: deleteButton)
        selectCategory(self.sections.first?.category)
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
        // Search is reserved for later; shown so the layout is in place.
        var searchConfiguration = UIButton.Configuration.filled()
        searchConfiguration.image = UIImage(systemName: "magnifyingglass")
        searchConfiguration.imagePadding = 6
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
        search.isEnabled = false
        search.accessibilityLabel = "搜尋繪文字（尚未提供）"

        let kinds: [(title: String?, image: String?, label: String, isActive: Bool)] = [
            (nil, "face.smiling", "繪文字", true),
            ("&%", nil, "符號（尚未提供）", false),
            (":-)", nil, "顏文字（尚未提供）", false),
        ]
        let kindButtons = kinds.map { kind -> UIButton in
            var configuration = kind.isActive ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = KeyboardButton.standardKeyColor
            configuration.baseForegroundColor = .label
            if let image = kind.image {
                configuration.image = UIImage(
                    systemName: image,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
                )
            }
            if let title = kind.title {
                configuration.attributedTitle = AttributedString(
                    title,
                    attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)])
                )
            }
            let button = UIButton(configuration: configuration)
            button.isEnabled = kind.isActive
            button.accessibilityLabel = kind.label
            if kind.isActive { button.accessibilityTraits.insert(.selected) }
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            return button
        }

        let bar = UIStackView(arrangedSubviews: [search] + kindButtons)
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

        let categories = UIStackView()
        categories.axis = .horizontal
        categories.distribution = .fillEqually
        for section in sections {
            let category = section.category
            let button = EmojiCategoryButton(type: .system)
            button.setImage(
                UIImage(
                    systemName: category.systemImage,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                ),
                for: .normal
            )
            button.tintColor = .secondaryLabel
            button.accessibilityLabel = category.title
            button.addAction(UIAction { [weak self] _ in self?.scroll(to: category) }, for: .touchUpInside)
            categoryButtons[category] = button
            categories.addArrangedSubview(button)
        }

        deleteButton.widthAnchor.constraint(equalToConstant: 42).isActive = true
        let bar = UIStackView(arrangedSubviews: [back, categories, deleteButton])
        bar.axis = .horizontal
        bar.spacing = 4
        return bar
    }

    // MARK: - Categories

    private func selectCategory(_ category: EmojiCategory?) {
        guard category != selectedCategory else { return }
        if let selectedCategory, let button = categoryButtons[selectedCategory] {
            button.tintColor = .secondaryLabel
            button.isCurrent = false
            button.accessibilityTraits.remove(.selected)
        }
        selectedCategory = category
        if let category, let button = categoryButtons[category] {
            button.tintColor = .label
            button.isCurrent = true
            button.accessibilityTraits.insert(.selected)
        }
    }

    private func scroll(to category: EmojiCategory) {
        guard let section = sections.firstIndex(where: { $0.category == category }) else { return }
        collectionView.layoutIfNeeded()
        let indexPath = IndexPath(item: 0, section: section)
        guard let header = collectionView.layoutAttributesForSupplementaryElement(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: indexPath
        ) else { return }
        let maximumOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)
        selectCategory(category)
        isScrollingToCategory = true
        collectionView.setContentOffset(CGPoint(x: 0, y: min(header.frame.minY, maximumOffset)), animated: false)
        isScrollingToCategory = false
    }

    /// The category whose content sits at the top of the visible grid.
    private func categoryAtTop() -> EmojiCategory? {
        let probe = collectionView.contentOffset.y + Metrics.headerHeight
        var current = sections.first?.category
        for (index, section) in sections.enumerated() {
            guard let header = collectionView.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader,
                at: IndexPath(item: 0, section: index)
            ) else { continue }
            if header.frame.minY <= probe { current = section.category } else { break }
        }
        return current
    }
}

extension EmojiPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].entries.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseIdentifier, for: indexPath)
        (cell as? EmojiCell)?.configure(with: sections[indexPath.section].entries[indexPath.item])
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
        (header as? EmojiSectionHeader)?.title = sections[indexPath.section].category.title
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        KeyHaptics.keyDown()
        onSelect?(sections[indexPath.section].entries[indexPath.item].emoji)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isScrollingToCategory else { return }
        selectCategory(categoryAtTop())
    }
}

/// A flow layout with `EmojiPanelView.Metrics.columns` square cells per row,
/// sized from the grid's current width.
private final class EmojiGridLayout: UICollectionViewFlowLayout {
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
            let side = floor(width / CGFloat(EmojiPanelView.Metrics.columns))
            if itemSize.width != side {
                itemSize = CGSize(width: side, height: side)
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
        label.font = .systemFont(ofSize: EmojiPanelView.Metrics.emojiFontSize)
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

    func configure(with entry: EmojiEntry) {
        label.text = entry.emoji
        accessibilityLabel = entry.emoji
        accessibilityIdentifier = "emoji-\(entry.emoji)"
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
