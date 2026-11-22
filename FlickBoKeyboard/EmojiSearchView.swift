import UIKit

/// The emoji search field: back to the palette, the query with its marked
/// (still composing) part underlined, and a clear button.
final class EmojiSearchFieldView: UIView {
    var onBack: (() -> Void)?
    var onClear: (() -> Void)?

    private let textLabel = UILabel()
    private let caret = UIView()
    private let clearButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let back = UIButton(type: .system)
        back.setImage(
            UIImage(systemName: "chevron.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)),
            for: .normal
        )
        back.tintColor = .label
        // Transparent otherwise; see `KeyboardSurface`.
        back.backgroundColor = KeyboardSurface.interactionColor
        back.accessibilityLabel = "返回繪文字"
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)

        let capsule = UIView()
        capsule.backgroundColor = KeyboardButton.standardKeyColor
        capsule.layer.cornerRadius = 18
        capsule.layer.cornerCurve = .continuous

        // Drawn like the palette's search button so both magnifiers match.
        var magnifierConfiguration = UIButton.Configuration.plain()
        magnifierConfiguration.image = UIImage(systemName: "magnifyingglass")
        magnifierConfiguration.preferredSymbolConfigurationForImage = EmojiPanelView.searchSymbolConfiguration
        magnifierConfiguration.baseForegroundColor = .secondaryLabel
        magnifierConfiguration.contentInsets = .zero
        let magnifier = UIButton(configuration: magnifierConfiguration)
        magnifier.isUserInteractionEnabled = false
        magnifier.isAccessibilityElement = false
        magnifier.setContentHuggingPriority(.required, for: .horizontal)

        textLabel.font = .systemFont(ofSize: 16)
        textLabel.lineBreakMode = .byTruncatingHead
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        caret.backgroundColor = .tintColor
        caret.layer.cornerRadius = 1
        caret.isUserInteractionEnabled = false

        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.tintColor = .tertiaryLabel
        clearButton.accessibilityLabel = "清除搜尋"
        clearButton.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let content = UIStackView(arrangedSubviews: [magnifier, textLabel, caret, spacer, clearButton])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 6
        content.setCustomSpacing(1, after: textLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(content)

        let row = UIStackView(arrangedSubviews: [back, capsule])
        row.axis = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            back.widthAnchor.constraint(equalToConstant: 36),
            content.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -8),
            content.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 2),
            caret.heightAnchor.constraint(equalToConstant: 20)
        ])
        startCaretBlink()
        update(committed: "", marked: "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(committed: String, marked: String) {
        let font = UIFont.systemFont(ofSize: 16)
        if committed.isEmpty, marked.isEmpty {
            textLabel.attributedText = NSAttributedString(
                string: "搜尋繪文字",
                attributes: [.font: font, .foregroundColor: UIColor.placeholderText]
            )
            // The caret sits before the placeholder, like an empty text field.
            if let content = caret.superview as? UIStackView, content.arrangedSubviews.firstIndex(of: caret) != 1 {
                content.removeArrangedSubview(caret)
                content.insertArrangedSubview(caret, at: 1)
            }
        } else {
            let text = NSMutableAttributedString(
                string: committed,
                attributes: [.font: font, .foregroundColor: UIColor.label]
            )
            text.append(NSAttributedString(
                string: marked,
                attributes: [
                    .font: font,
                    .foregroundColor: UIColor.label,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ]
            ))
            textLabel.attributedText = text
            if let content = caret.superview as? UIStackView, content.arrangedSubviews.firstIndex(of: caret) != 2 {
                content.removeArrangedSubview(caret)
                content.insertArrangedSubview(caret, at: 2)
            }
        }
        clearButton.isHidden = committed.isEmpty && marked.isEmpty
        accessibilityValue = committed + marked
    }

    private func startCaretBlink() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.5
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        caret.layer.add(animation, forKey: "blink")
    }
}

/// One horizontally scrolling row of search results, or a hint when there
/// is nothing to show.
final class EmojiSearchResultsView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    var onSelect: ((String) -> Void)?

    private var results: [String] = []
    private let collectionView: UICollectionView
    private let hintLabel = UILabel()

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 40, height: 40)
        layout.minimumLineSpacing = 2
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)

        collectionView.backgroundColor = KeyboardSurface.interactionColor
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ResultCell.self, forCellWithReuseIdentifier: ResultCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)

        hintLabel.font = .systemFont(ofSize: 14)
        hintLabel.textColor = .secondaryLabel
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(results: [String], hasQuery: Bool) {
        let changed = results != self.results
        self.results = results
        hintLabel.text = hasQuery ? "找不到相符的繪文字" : "輸入中文或英文搜尋繪文字"
        hintLabel.isHidden = !results.isEmpty
        guard changed else { return }
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        results.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ResultCell.reuseIdentifier, for: indexPath)
        (cell as? ResultCell)?.configure(with: results[indexPath.item])
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        KeyHaptics.keyDown()
        onSelect?(results[indexPath.item])
    }
}

private final class ResultCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiSearchResultCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 28)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        contentView.layer.cornerRadius = 8
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
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

    func configure(with emoji: String) {
        label.text = emoji
        accessibilityLabel = emoji
        accessibilityIdentifier = "search-emoji-\(emoji)"
    }
}
