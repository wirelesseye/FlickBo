import UIKit

enum CandidateMetrics {
    static let contentInsets = UIEdgeInsets(top: 2, left: 10, bottom: 2, right: 10)
    static let itemHeight: CGFloat = 40

    static let badgeFont = UIFont.systemFont(ofSize: 9, weight: .regular)
    static let badgeSpacing: CGFloat = 1

    /// Extra width reserved to the right of the title for a corner badge.
    static func badgeWidth(_ badge: String?) -> CGFloat {
        guard let badge else { return 0 }
        return ceil((badge as NSString).size(withAttributes: [.font: badgeFont]).width) + badgeSpacing
    }

    static func itemWidth(_ item: CandidateItem) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .title3)
        let width = ceil((item.text as NSString).size(withAttributes: [.font: font]).width)
        return width + contentInsets.left + contentInsets.right + badgeWidth(item.badge)
    }

    static func cacheKey(_ item: CandidateItem) -> String {
        item.badge.map { $0 + "\u{1F}" + item.text } ?? item.text
    }
}

final class CandidateCell: UICollectionViewCell {
    static let reuseIdentifier = "CandidateCell"

    private(set) var candidate: CandidateItem?
    private var onSelect: ((CandidateItem) -> Void)?
    private let button = CandidateButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            button.topAnchor.constraint(equalTo: contentView.topAnchor),
            button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        button.addAction(
            UIAction { [weak self] _ in
                guard let self, let candidate else { return }
                KeyHaptics.keyDown()
                onSelect?(candidate)
            },
            for: .touchUpInside
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with candidate: CandidateItem,
        adjustsTitleToFit: Bool,
        onSelect: @escaping (CandidateItem) -> Void
    ) {
        self.candidate = candidate
        self.onSelect = onSelect
        button.update(with: candidate, adjustsTitleToFit: adjustsTitleToFit)
    }
}

final class CandidateBarView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSelect: ((CandidateItem) -> Void)?
    var onToggleExpansion: (() -> Void)?
    var onVisibleCandidatesChanged: ((Int) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onDismissKeyboard: (() -> Void)?
    var onToggleCharacterWidth: (() -> Void)?
    var onSelectCharacterVariant: ((CharacterVariant) -> Void)?
    var characterVariant: CharacterVariant = .taiwan
    var characterWidth: CharacterWidth = .half {
        didSet { updateWidthButton() }
    }

    private(set) var isExpanded = false
    private(set) var visibleCandidateCount = 0
    private var isTransitioningExpansion = false
    private var isAdjustingLayout = false
    private var hasCandidates = false
    private var candidates: [CandidateItem] = []
    private var widthCache: [String: CGFloat] = [:]

    static let animationDuration: TimeInterval = 0.25

    private static let collapsedSpacing: CGFloat = 2
    private static let contentInset: CGFloat = 4
    private static let expandSymbolPointSize: CGFloat = 13
    private static let expandButtonLeadingInset: CGFloat = 8
    private static let expandButtonContentWidth: CGFloat = 36
    private static let dividerHeight: CGFloat = 20

    private let flowLayout = UICollectionViewFlowLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    private let expandButton = UIButton(type: .system)
    private let dividerView = UIView()
    private let hitSurfaceView = UIView()
    private let toolbarView = UIStackView()
    private let settingsButton = ToolbarButton()
    private let dismissButton = ToolbarButton()
    private let widthButton = ToolbarButton()
    private let variantButton = ToolbarButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.contentSizeCategoryDidChange()
        }

        flowLayout.scrollDirection = .horizontal
        flowLayout.minimumInteritemSpacing = Self.collapsedSpacing
        flowLayout.minimumLineSpacing = 0
        flowLayout.sectionInset = UIEdgeInsets(
            top: 0,
            left: Self.contentInset,
            bottom: 0,
            right: Self.contentInset
        )

        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            CandidateCell.self,
            forCellWithReuseIdentifier: CandidateCell.reuseIdentifier
        )
        collectionView.backgroundColor = KeyboardSurface.interactionColor
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.alwaysBounceHorizontal = false
        collectionView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = true
            collectionView.leftEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
            collectionView.rightEdgeEffect.isHidden = true
        }
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        var expandConfiguration = UIButton.Configuration.plain()
        expandConfiguration.image = Self.expandSymbol(expanded: false)
        expandConfiguration.baseForegroundColor = .label
        expandConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: Self.expandButtonLeadingInset,
            bottom: 0,
            trailing: 0
        )
        expandButton.configuration = expandConfiguration
        expandButton.backgroundColor = .clear
        expandButton.accessibilityIdentifier = "candidate-expand-toggle"
        expandButton.accessibilityLabel = "展開候選字詞"
        expandButton.isEnabled = false
        expandButton.alpha = 0.4
        expandButton.isHidden = true
        expandButton.translatesAutoresizingMaskIntoConstraints = false
        expandButton.addAction(
            UIAction { [weak self] _ in self?.toggleExpansion() },
            for: .touchUpInside
        )
        addSubview(expandButton)

        dividerView.backgroundColor = .separator
        dividerView.isAccessibilityElement = false
        dividerView.isUserInteractionEnabled = false
        dividerView.isHidden = true
        dividerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dividerView)

        // Keyboard extensions are hosted in a remote window whose input region can
        // omit fully transparent pixels. Render an imperceptible surface so the
        // whole area to the right of the divider remains part of that input region.
        hitSurfaceView.backgroundColor = KeyboardSurface.interactionColor
        hitSurfaceView.isUserInteractionEnabled = false
        insertSubview(hitSurfaceView, belowSubview: expandButton)

        // Toolbar shown in place of candidates while there is no input.
        settingsButton.image = UIImage(
            systemName: "gearshape",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        settingsButton.accessibilityIdentifier = "toolbar-settings"
        settingsButton.accessibilityLabel = "設定"
        settingsButton.addAction(
            UIAction { [weak self] _ in self?.onOpenSettings?() },
            for: .touchUpInside
        )
        settingsButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        dismissButton.image = UIImage(
            systemName: "keyboard.chevron.compact.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        dismissButton.accessibilityIdentifier = "toolbar-dismiss-keyboard"
        dismissButton.accessibilityLabel = "隱藏鍵盤"
        dismissButton.addAction(
            UIAction { [weak self] _ in self?.onDismissKeyboard?() },
            for: .touchUpInside
        )
        dismissButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        widthButton.accessibilityIdentifier = "toolbar-character-width"
        widthButton.addAction(
            UIAction { [weak self] _ in
                KeyHaptics.keyDown()
                self?.onToggleCharacterWidth?()
            },
            for: .touchUpInside
        )
        widthButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        updateWidthButton()

        variantButton.image = UIImage(
            systemName: "bubble.and.pencil",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        )
        variantButton.accessibilityIdentifier = "toolbar-character-variant"
        variantButton.accessibilityLabel = "字形"
        // Built on each tap so the checkmark follows the current variant.
        variantButton.menuProvider = { [weak self] in self?.characterVariantMenu() }
        variantButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let toolbarSpacer = UIView()
        toolbarSpacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)

        toolbarView.axis = .horizontal
        toolbarView.alignment = .fill
        toolbarView.spacing = 4
        toolbarView.addArrangedSubview(settingsButton)
        toolbarView.addArrangedSubview(widthButton)
        toolbarView.addArrangedSubview(variantButton)
        toolbarView.addArrangedSubview(toolbarSpacer)
        toolbarView.addArrangedSubview(dismissButton)
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarView)

        NSLayoutConstraint.activate([
            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.contentInset),
            toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.contentInset),
            toolbarView.topAnchor.constraint(equalTo: topAnchor),
            toolbarView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: dividerView.leadingAnchor, constant: -8),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dividerView.trailingAnchor.constraint(equalTo: expandButton.leadingAnchor),
            dividerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dividerView.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            dividerView.heightAnchor.constraint(equalToConstant: Self.dividerHeight),
            expandButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            expandButton.widthAnchor.constraint(
                equalToConstant: Self.expandButtonLeadingInset + Self.expandButtonContentWidth
            ),
            expandButton.heightAnchor.constraint(equalTo: heightAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(with candidates: [InputCandidate]) {
        update(with: candidates.map(CandidateItem.input))
    }

    func update(with candidates: [CandidateItem]) {
        guard candidates != self.candidates else { return }
        self.candidates = candidates
        UIView.performWithoutAnimation {
            isAdjustingLayout = true
            defer { isAdjustingLayout = false }
            collectionView.reloadData()
            collectionView.setContentOffset(.zero, animated: false)
            flowLayout.minimumInteritemSpacing = Self.collapsedSpacing
            flowLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
            updateVisibleCandidateCount()
            if isExpanded {
                applyExpandedPresentation()
            }
        }
        let hasCandidates = !candidates.isEmpty
        self.hasCandidates = hasCandidates
        expandButton.isHidden = !hasCandidates
        dividerView.isHidden = !hasCandidates || isExpanded
        expandButton.isEnabled = hasCandidates
        expandButton.alpha = hasCandidates ? 1 : 0.4
        toolbarView.isHidden = hasCandidates
    }

    func setExpanded(_ expanded: Bool, completion: (() -> Void)? = nil) {
        guard isExpanded != expanded else {
            completion?()
            return
        }
        isExpanded = expanded
        expandButton.configuration?.image = Self.expandSymbol(expanded: expanded)
        expandButton.accessibilityLabel = expanded ? "收合候選字詞" : "展開候選字詞"
        dividerView.isHidden = expanded || !hasCandidates
        collectionView.isScrollEnabled = !expanded
        collectionView.setContentOffset(.zero, animated: false)
        setExtrasAccessibilityHidden(expanded)
        isTransitioningExpansion = true
        UIView.animate(
            withDuration: Self.animationDuration,
            delay: 0,
            options: [.curveEaseInOut],
            animations: {
                if expanded {
                    self.applyExpandedSpacing()
                } else {
                    self.flowLayout.minimumInteritemSpacing = Self.collapsedSpacing
                    self.flowLayout.invalidateLayout()
                }
                self.collectionView.layoutIfNeeded()
            },
            completion: { [weak self] _ in
                guard let self else { return }
                self.isTransitioningExpansion = false
                if !self.isExpanded {
                    self.updateVisibleCandidateCount()
                }
                completion?()
            }
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hitSurfaceView.frame = CGRect(
            x: dividerView.frame.maxX,
            y: bounds.minY,
            width: max(0, bounds.maxX - dividerView.frame.maxX),
            height: bounds.height
        )
        if isExpanded, collectionView.contentOffset != .zero {
            collectionView.setContentOffset(.zero, animated: false)
        }
        guard !isTransitioningExpansion, !isAdjustingLayout else { return }
        updateVisibleCandidateCount()
        if isExpanded {
            applyExpandedSpacing()
        }
    }

    private static func expandSymbol(expanded: Bool) -> UIImage? {
        UIImage(
            systemName: expanded ? "chevron.up" : "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: expandSymbolPointSize, weight: .medium)
        )
    }

    private func contentSizeCategoryDidChange() {
        widthCache.removeAll()
        flowLayout.invalidateLayout()
        layoutIfNeeded()
        updateVisibleCandidateCount()
        if isExpanded {
            applyExpandedSpacing()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isExpanded, scrollView.contentOffset != .zero else { return }
        scrollView.setContentOffset(.zero, animated: false)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let isInExpansionRegion =
            !expandButton.isHidden
            && expandButton.isEnabled
            && bounds.contains(point)
            && point.x >= dividerView.frame.maxX

        guard isInExpansionRegion else { return super.hitTest(point, with: event) }

        return expandButton
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        candidates.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: CandidateCell.reuseIdentifier,
            for: indexPath
        )
        guard let candidateCell = cell as? CandidateCell else { return cell }
        candidateCell.configure(
            with: candidates[indexPath.item],
            adjustsTitleToFit: false
        ) { [weak self] selected in
            self?.onSelect?(selected)
        }
        return candidateCell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(
            width: itemWidth(for: candidates[indexPath.item]),
            height: max(collectionView.bounds.height, CandidateMetrics.itemHeight)
        )
    }

    private func characterVariantMenu() -> UIMenu {
        UIMenu(
            options: .singleSelection,
            children: CharacterVariant.allCases.map { variant in
                UIAction(
                    title: variant.title,
                    state: variant == characterVariant ? .on : .off
                ) { [weak self] _ in
                    self?.onSelectCharacterVariant?(variant)
                }
            }
        )
    }

    private func updateWidthButton() {
        let isFull = characterWidth == .full
        widthButton.image = UIImage(
            systemName: isFull ? "inset.filled.circle.dashed" : "circle.lefthalf.filled",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        widthButton.accessibilityLabel = isFull ? "全形，點按切換為半形" : "半形，點按切換為全形"
    }

    private func toggleExpansion() {
        KeyHaptics.keyDown()
        onToggleExpansion?()
    }

    private func itemWidth(for item: CandidateItem) -> CGFloat {
        let key = CandidateMetrics.cacheKey(item)
        if let cached = widthCache[key] {
            return cached
        }
        let width = CandidateMetrics.itemWidth(item)
        widthCache[key] = width
        return width
    }

    private func updateVisibleCandidateCount() {
        collectionView.layoutIfNeeded()
        let visibleWidth = collectionView.bounds.width - Self.contentInset
        var count = 0
        for index in 0..<candidates.count {
            guard let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
            ) else { break }
            guard attributes.frame.maxX - Self.contentInset <= visibleWidth + 0.5 else { break }
            count += 1
        }
        guard count != visibleCandidateCount else { return }
        visibleCandidateCount = count
        onVisibleCandidatesChanged?(count)
    }

    private func applyExpandedPresentation() {
        applyExpandedSpacing()
        setExtrasAccessibilityHidden(true)
        collectionView.layoutIfNeeded()
        layoutIfNeeded()
    }

    private func applyExpandedSpacing() {
        let spacing = computedExpandedSpacing()
        guard flowLayout.minimumInteritemSpacing != spacing else { return }
        flowLayout.minimumInteritemSpacing = spacing
        flowLayout.invalidateLayout()
    }

    private func computedExpandedSpacing() -> CGFloat {
        let count = visibleCandidateCount
        guard count > 0 else { return Self.collapsedSpacing }
        var contentWidth: CGFloat = 0
        for index in 0..<count {
            guard let attributes = collectionView.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0)
            ) else { break }
            contentWidth += attributes.frame.width
        }
        let availableWidth = collectionView.bounds.width - 2 * Self.contentInset
        let spacing = (availableWidth - contentWidth) / CGFloat(max(1, count - 1))
        return max(Self.collapsedSpacing, spacing)
    }

    private func setExtrasAccessibilityHidden(_ hidden: Bool) {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            cell.accessibilityElementsHidden = hidden && indexPath.item >= visibleCandidateCount
        }
    }
}

/// Plain control with the key-colored pressed background shared by candidates and toolbar icons.
/// A `UIControl` instead of `UIButton` so layout doesn't depend on deprecated button insets.
class CandidateHighlightControl: UIControl {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? KeyboardButton.standardKeyColor : .clear }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class CandidateButton: CandidateHighlightControl {
    let titleLabel = UILabel()
    private let badgeLabel = UILabel()
    private var titleLeading: NSLayoutConstraint!
    private var titleTrailing: NSLayoutConstraint!

    var badgeText: String? { badgeLabel.isHidden ? nil : badgeLabel.text }

    /// Horizontal space around the title; the right side includes room for a badge.
    private(set) var titleInsets = CandidateMetrics.contentInsets {
        didSet {
            titleLeading.constant = titleInsets.left
            titleTrailing.constant = -titleInsets.right
        }
    }

    func update(with candidate: CandidateItem, adjustsTitleToFit: Bool) {
        badgeLabel.text = candidate.badge
        badgeLabel.isHidden = candidate.badge == nil
        var insets = CandidateMetrics.contentInsets
        insets.right += CandidateMetrics.badgeWidth(candidate.badge)
        titleInsets = insets
        titleLabel.text = candidate.text
        titleLabel.adjustsFontSizeToFitWidth = adjustsTitleToFit
        titleLabel.minimumScaleFactor = adjustsTitleToFit ? 0.6 : 1
        accessibilityIdentifier = candidate.accessibilityIdentifier
        accessibilityLabel = candidate.accessibilityLabel
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byClipping
        titleLabel.isAccessibilityElement = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // Occupies its own space right of the title; `update` widens the right inset for it.
        badgeLabel.font = CandidateMetrics.badgeFont
        badgeLabel.textColor = .secondaryLabel
        badgeLabel.isHidden = true
        badgeLabel.isAccessibilityElement = false
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeLabel)

        titleLeading = titleLabel.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: titleInsets.left
        )
        titleTrailing = titleLabel.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -titleInsets.right
        )
        NSLayoutConstraint.activate([
            titleLeading,
            titleTrailing,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            badgeLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -CandidateMetrics.contentInsets.right
            )
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Toolbar icon button that highlights with a key-colored background, matching candidates.
final class ToolbarButton: CandidateHighlightControl {
    private let imageView = UIImageView()

    var image: UIImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    /// When set, a tap shows this menu instead of sending `.touchUpInside`.
    var menuProvider: (() -> UIMenu?)? {
        didSet {
            isContextMenuInteractionEnabled = menuProvider != nil
            showsMenuAsPrimaryAction = menuProvider != nil
        }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menuProvider else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menuProvider() })
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.tintColor = .label
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
