//
//  TextKit2SuffixPresentation.swift
//  TwitterTextEditor
//
//  SPDX-License-Identifier: Apache-2.0
//

import CoreText
import UIKit

/// Direction-neutral metrics for one Core Text shaping cluster.
///
/// Both presentation layout and custom-fragment drawing consume the same Core Text
/// cluster boundaries. Keeping the extraction here guarantees that each caller shapes a
/// line once, then derives every cluster from the resulting runs instead of repeatedly
/// rebuilding an identical `CTLine` for each UTF-16 range.
private struct CoreTextClusterMetric {
    let range: NSRange
    let isRightToLeft: Bool
    let advance: CGFloat
    let usesCaretAdvance: Bool
}

/// Identifies one logical caret edge reported by Core Text.
private struct CoreTextCaretEdge: Hashable {
    let stringIndex: Int
    let isLeading: Bool
}

/// Collects every logical caret edge with one visual-order line traversal.
///
/// Unlike glyph advances, caret edges already account for negative mark positioning,
/// ligatures, bidirectional affinity, and the line's actual shaping context. A cluster's
/// inline span is therefore the distance between its first leading edge and its last
/// trailing edge.
private func coreTextCaretOffsets(in line: CTLine) -> [CoreTextCaretEdge: CGFloat] {
    var offsets = [CoreTextCaretEdge: CGFloat]()
    CTLineEnumerateCaretOffsets(line) { offset, stringIndex, leadingEdge, _ in
        offsets[
            CoreTextCaretEdge(
                stringIndex: stringIndex,
                isLeading: leadingEdge
            )
        ] = CGFloat(offset)
    }
    return offsets
}

/// Returns the logical caret span for a nonempty UTF-16 range when both edges exist.
private func coreTextCaretSpan(
    of range: NSRange,
    offsets: [CoreTextCaretEdge: CGFloat]
) -> (minimum: CGFloat, width: CGFloat)? {
    guard range.length > 0,
          let start = offsets[
              CoreTextCaretEdge(stringIndex: range.location, isLeading: true)
          ],
          let end = offsets[
              CoreTextCaretEdge(stringIndex: range.upperBound - 1, isLeading: false)
          ] else {
        return nil
    }
    return (min(start, end), abs(start - end))
}

/// Extracts every logical shaping cluster and advance from one already-shaped line.
///
/// Core Text exposes glyphs in visual order, while its string indices remain logical.
/// Unique sorted indices therefore delimit the logical clusters. Multiple glyphs can own
/// the same string index, so their absolute advances are accumulated before the metric is
/// emitted. The work is linear apart from sorting each run's distinct boundaries.
private func coreTextClusterMetrics(
    in line: CTLine,
    attributedString: NSAttributedString
) -> [CoreTextClusterMetric] {
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    let caretOffsets = coreTextCaretOffsets(in: line)
    var rawClusters = [CoreTextClusterMetric]()

    for run in runs {
        let runRange = CTRunGetStringRange(run)
        let runEnd = runRange.location + runRange.length
        let glyphCount = CTRunGetGlyphCount(run)
        var indices = [CFIndex](repeating: 0, count: glyphCount)
        var advances = [CGSize](repeating: .zero, count: glyphCount)
        if glyphCount > 0 {
            CTRunGetStringIndices(
                run,
                CFRange(location: 0, length: glyphCount),
                &indices
            )
            CTRunGetAdvances(
                run,
                CFRange(location: 0, length: glyphCount),
                &advances
            )
        }

        var boundaries = [runRange.location, runEnd]
        var advanceByStringLocation = [Int: CGFloat]()
        let usesCaretAdvance = advances.contains { advance in
            advance.width < 0
        }
        for (index, advance) in zip(indices, advances)
        where index >= runRange.location && index < runEnd {
            boundaries.append(index)
            // Combining marks can carry a negative positioning advance. Preserve its
            // sign here and fold it into the composed carrier below; treating it as an
            // independent positive width makes Arabic diacritics reserve phantom space.
            advanceByStringLocation[index, default: 0] += advance.width
        }

        let sortedBoundaries = Array(Set(boundaries)).sorted()
        let isRightToLeft = CTRunGetStatus(run).contains(.rightToLeft)
        for (start, end) in zip(
            sortedBoundaries,
            sortedBoundaries.dropFirst()
        ) where end > start {
            rawClusters.append(
                CoreTextClusterMetric(
                    range: NSRange(location: start, length: end - start),
                    isRightToLeft: isRightToLeft,
                    advance: advanceByStringLocation[start, default: 0],
                    usesCaretAdvance: usesCaretAdvance
                )
            )
        }
    }

    guard !rawClusters.isEmpty else {
        return []
    }

    // Core Text string indices can split a user-perceived character when a positioning
    // glyph (Arabic harakat, Indic marks, variation selectors, or a ZWJ) has its own
    // index. A suffix belongs to the composed sequence selected by the public API, so
    // merge every raw shaping interval connected by the same composed sequence. The
    // union keeps the base and its negative/zero-advance marks under one font matrix.
    var parent = Array(rawClusters.indices)
    func root(of index: Int) -> Int {
        var index = index
        while parent[index] != index {
            parent[index] = parent[parent[index]]
            index = parent[index]
        }
        return index
    }
    func unite(_ lhs: Int, _ rhs: Int) {
        let lhsRoot = root(of: lhs)
        let rhsRoot = root(of: rhs)
        if lhsRoot != rhsRoot {
            parent[rhsRoot] = lhsRoot
        }
    }

    var rawClusterByStringLocation = [Int: Int]()
    for (index, cluster) in rawClusters.enumerated() {
        for location in cluster.range.location..<cluster.range.upperBound {
            rawClusterByStringLocation[location] = index
        }
    }
    let string = attributedString.string
    let fullRange = NSRange(location: 0, length: attributedString.length)
    if let swiftRange = Range(fullRange, in: string) {
        string.enumerateSubstrings(
            in: swiftRange,
            options: .byComposedCharacterSequences
        ) { _, substringRange, _, _ in
            let composedRange = NSRange(substringRange, in: string)
            let connectedIndices = Set(
                (composedRange.location..<composedRange.upperBound).compactMap { location in
                    rawClusterByStringLocation[location]
                }
            )
            guard let first = connectedIndices.first else {
                return
            }
            for index in connectedIndices.dropFirst() {
                unite(first, index)
            }
        }
    }

    var indicesByRoot = [Int: [Int]]()
    for index in rawClusters.indices {
        indicesByRoot[root(of: index), default: []].append(index)
    }
    return indicesByRoot.values.map { indices in
        let members = indices.map { rawClusters[$0] }
        let lowerBound = members.map(\.range.location).min() ?? 0
        let upperBound = members.map(\.range.upperBound).max() ?? lowerBound
        let range = NSRange(location: lowerBound, length: upperBound - lowerBound)
        let usesCaretAdvance = indices.count > 1
            || members.contains(where: \.usesCaretAdvance)
        return CoreTextClusterMetric(
            range: range,
            isRightToLeft: members.allSatisfy(\.isRightToLeft),
            advance: usesCaretAdvance
                ? coreTextCaretSpan(of: range, offsets: caretOffsets)?.width
                    ?? abs(members.reduce(0) { $0 + $1.advance })
                : abs(members.reduce(0) { $0 + $1.advance }),
            usesCaretAdvance: usesCaretAdvance
        )
    }.sorted { lhs, rhs in
        lhs.range.location < rhs.range.location
    }
}

/// Measures several known cluster ranges with one Core Text shaping pass.
///
/// Attribute boundaries ensure that every glyph's string index belongs to at most one
/// requested range. Expanding the ranges into a UTF-16 lookup table makes the subsequent
/// glyph walk linear in paragraph length and avoids a range-by-glyph nested scan.
private func coreTextAdvances(
    of ranges: [NSRange],
    in line: CTLine,
    caretAdvanceIndices: Set<Int> = []
) -> [CGFloat] {
    guard !ranges.isEmpty else {
        return []
    }

    let caretOffsets = coreTextCaretOffsets(in: line)

    var rangeIndexByStringLocation = [Int: Int]()
    rangeIndexByStringLocation.reserveCapacity(
        ranges.reduce(0) { partialResult, range in
            partialResult + range.length
        }
    )
    for (rangeIndex, range) in ranges.enumerated() {
        for location in range.location..<range.upperBound {
            rangeIndexByStringLocation[location] = rangeIndex
        }
    }

    var result = [CGFloat](repeating: 0, count: ranges.count)
    let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
    for run in runs {
        let glyphCount = CTRunGetGlyphCount(run)
        guard glyphCount > 0 else {
            continue
        }
        var indices = [CFIndex](repeating: 0, count: glyphCount)
        var advances = [CGSize](repeating: .zero, count: glyphCount)
        CTRunGetStringIndices(
            run,
            CFRange(location: 0, length: glyphCount),
            &indices
        )
        CTRunGetAdvances(
            run,
            CFRange(location: 0, length: glyphCount),
            &advances
        )
        for (index, advance) in zip(indices, advances) {
            guard let rangeIndex = rangeIndexByStringLocation[index] else {
                continue
            }
            result[rangeIndex] += advance.width
        }
    }
    return zip(ranges.indices, zip(ranges, result)).map { index, value in
        let (range, signedAdvance) = value
        if caretAdvanceIndices.contains(index),
           let caretSpan = coreTextCaretSpan(of: range, offsets: caretOffsets) {
            return caretSpan.width
        }
        return abs(signedAdvance)
    }
}

/**
 Presents `TextAttributes.SuffixedAttachment` values without changing the editor's
 backing string.

 TextKit 2 has no glyph-insertion API. A native `NSTextAttachment` would add an
 attachment character to the text and would therefore change public UTF-16 ranges,
 selection, copy/paste, undo, and marked-text behavior. Instead, this object gives
 `NSTextContentStorage` an equal-length presentation paragraph:

 - the custom suffix attribute is removed before TextKit lays out the paragraph;
 - standard tracking reserves an LTR gap at a shaping-cluster boundary;
 - horizontally transformed, transparent fonts give every affected RTL shaping cluster
   its exact clean advance, plus the suffix width on the host cluster;
 - a custom TextKit 2 layout fragment restores the original contextual RTL glyphs;
 - the image or view is overlaid after TextKit has produced caret geometry.

 The presentation string preserves the backing string's UTF-16 code units, so the
 editor keeps a single position space for UIKit, clients, and input methods. Suffix
 height intentionally does not alter line metrics; this matches the previous
 control-glyph implementation and avoids moving the host glyph or selection geometry.

 `NSTextContentStorage.delegate` is weak. `TextEditorView` therefore retains this
 object for the lifetime of its text view.
 */
final class TextKit2SuffixPresentation: NSObject,
    NSTextContentStorageDelegate,
    NSTextLayoutManagerDelegate
{
    /// Identifies one rendered image without relying on an attributed run's extent.
    ///
    /// The same attachment value may be applied to adjacent graphemes. Combining the
    /// UTF-16 location and object identity gives every visual suffix its own image view.
    private struct ImageKey: Hashable {
        let location: Int
        let suffix: ObjectIdentifier
    }

    /// A Core Text shaping cluster and the metrics of the run that owns it.
    ///
    /// `advance` is captured from the clean paragraph before presentation-only attributes
    /// split its runs. It is the target width used to neutralize contextual-shaping changes
    /// on every nonhost RTL cluster.
    private struct ShapingCluster {
        let range: NSRange
        let isRightToLeft: Bool
        let advance: CGFloat
        let usesCaretAdvance: Bool
    }

    /// One public suffix and the composed-character range that owns it.
    private struct SuffixEntry {
        let characterRange: NSRange
        let suffix: TextAttributes.SuffixedAttachment
    }

    /// All suffixes that share one indivisible shaping cluster.
    private struct SuffixGroup {
        let cluster: ShapingCluster
        let entries: [SuffixEntry]

        var width: CGFloat {
            entries.reduce(0) { partialResult, entry in
                partialResult + entry.suffix.size.width
            }
        }
    }

    /// A laid-out line and its origin in the text container coordinate space.
    private struct LaidOutLine {
        let line: NSTextLineFragment
        let characterRange: NSRange
        let origin: CGPoint
    }

    /// Identifies an affected paragraph while TextKit owns its presentation fragment.
    ///
    /// The backing text storage can mutate after a fragment is created. Capturing the
    /// equal-length clean paragraph at creation time makes drawing self-contained and
    /// prevents later offsets from being applied to an older layout fragment.
    fileprivate struct DrawingParagraph {
        let documentRange: NSRange
        let cleanAttributedString: NSAttributedString
        let suffixWidthsByClusterLocation: [Int: CGFloat]
    }

    private var imageViews: [ImageKey: UIImageView] = [:]

    /// Geometry-only inputs captured from the TextKit 2 object graph.
    private weak var textContainer: NSTextContainer?
    private weak var textLayoutManager: NSTextLayoutManager?
    private var availableLayoutWidth: CGFloat?

    /// UIKit's private TextKit 2 controller remains the authority for behaviors this
    /// presentation object does not customize, such as system link rendering.
    /// `NSTextLayoutManager.delegate` is weak, and UITextView retains its controller, so a
    /// weak forwarding reference preserves UIKit ownership without introducing a cycle.
    private weak var forwardedLayoutDelegate: (any NSTextLayoutManagerDelegate)?

    /// Installs this object as a narrow proxy in front of UITextView's layout delegate.
    ///
    /// TextKit exposes one delegate slot. Replacing UIKit's existing delegate outright
    /// drops optional system behavior even for paragraphs without suffixes. Capture it
    /// first, then forward every selector this class does not implement itself.
    func install(on textLayoutManager: NSTextLayoutManager) {
        guard textLayoutManager.delegate !== self else {
            return
        }
        forwardedLayoutDelegate = textLayoutManager.delegate
        textContainer = textLayoutManager.textContainer
        self.textLayoutManager = textLayoutManager
        textLayoutManager.delegate = self
    }

    /// Updates width-dependent presentation input before UITextView lays out its viewport.
    ///
    /// NSTextContainer temporarily reports zero during an Auto Layout resize. Deriving the
    /// width from the already-resolved view bounds keeps presentation construction from
    /// treating that transient value as an unbounded line. Layout invalidation is the first
    /// supported attempt to make TextKit discard width-dependent presentation paragraphs.
    func prepareLayout(in textView: UITextView) {
        let width = Self.availableWidth(in: textView, outerWidth: textView.bounds.width)
        guard width > 0 else {
            return
        }
        let previousWidth = availableLayoutWidth
        availableLayoutWidth = width
        guard previousWidth == nil || abs(previousWidth! - width) > 0.001 else {
            return
        }
        rebuildPresentationParagraphs(in: textView)
    }

    /// Measures at the caller's proposed width without editing the live backing storage.
    ///
    /// `UITextView.sizeThatFits(_:)` can propose a width that differs from the live bounds,
    /// while RTL carrier calibration is width-dependent. Rebuilding the live presentation
    /// would emit real NSTextStorage attribute-edit notifications twice: once for the
    /// proposal and again for the restored width. Instead, copy the public attributed
    /// content and text-container geometry into a short-lived TextKit 2 view. Its own
    /// presentation delegate can rebuild freely without touching selection, marked text,
    /// observers, or undo state in the editor being measured.
    func sizeThatFits(_ size: CGSize, in textView: UITextView) -> CGSize {
        let proposedWidth = Self.availableWidth(in: textView, outerWidth: size.width)
        guard proposedWidth.isFinite, proposedWidth > 0 else {
            return textView.sizeThatFits(size)
        }

        let measurementView = TextView(
            frame: CGRect(
                origin: .zero,
                size: CGSize(width: size.width, height: textView.bounds.height)
            ),
            textContainer: nil
        )
        guard let measurementLayoutManager = measurementView.textLayoutManager,
              let measurementContentStorage = measurementLayoutManager.textContentManager
                as? NSTextContentStorage else {
            return textView.sizeThatFits(size)
        }
        measurementView.textContainerInset = textView.textContainerInset
        measurementView.textContainer.lineFragmentPadding = textView.textContainer
            .lineFragmentPadding
        measurementView.textContainer.lineBreakMode = textView.textContainer.lineBreakMode
        measurementView.textContainer.maximumNumberOfLines = textView.textContainer
            .maximumNumberOfLines
        measurementView.textContainer.exclusionPaths = textView.textContainer.exclusionPaths
        measurementView.isScrollEnabled = textView.isScrollEnabled
        measurementView.linkTextAttributes = textView.linkTextAttributes
        measurementView.attributedText = NSAttributedString(
            attributedString: textView.textStorage
        )
        measurementView.typingAttributes = textView.typingAttributes

        let measurementPresentation = TextKit2SuffixPresentation()
        measurementContentStorage.delegate = measurementPresentation
        measurementPresentation.install(on: measurementLayoutManager)
        measurementPresentation.prepareLayout(in: measurementView)
        return measurementView.sizeThatFits(size)
    }

    /// Converts a view or proposal width into TextKit's inline content width.
    private static func availableWidth(in textView: UITextView, outerWidth: CGFloat) -> CGFloat {
        max(
            0,
            outerWidth
                - textView.textContainerInset.left
                - textView.textContainerInset.right
                - 2 * textView.textContainer.lineFragmentPadding
        )
    }

    /// Makes NSTextContentStorage discard cached custom paragraphs after width changes.
    private func rebuildPresentationParagraphs(in textView: UITextView) {
        guard let textLayoutManager,
              let textContentManager = textLayoutManager.textContentManager else {
            return
        }
        // `invalidateLayout(for:)`, including inside an editing transaction, invalidates
        // fragment geometry but keeps the equal-length presentation paragraph cached by
        // NSTextContentStorage. Reapply only the library-owned suffix metadata so the
        // content delegate is asked for a width-specific paragraph again. This is a real
        // attribute edit and therefore emits normal NSTextStorage attribute-edit
        // notifications; callers never receive fabricated character edits, and the path
        // runs only when the resolved inline layout width actually changes.
        let backingStore = textView.textStorage
        let fullRange = NSRange(location: 0, length: backingStore.length)
        var suffixRuns = [(value: Any, range: NSRange)]()
        backingStore.enumerateAttribute(.suffixedAttachment, in: fullRange) { value, range, _ in
            if let value {
                suffixRuns.append((value, range))
            }
        }
        guard !suffixRuns.isEmpty else {
            textLayoutManager.invalidateLayout(for: textContentManager.documentRange)
            return
        }
        backingStore.beginEditing()
        for run in suffixRuns {
            backingStore.removeAttribute(.suffixedAttachment, range: run.range)
            backingStore.addAttribute(
                .suffixedAttachment,
                value: run.value,
                range: run.range
            )
        }
        backingStore.endEditing()
        textLayoutManager.invalidateLayout(for: textContentManager.documentRange)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector)
            || forwardedLayoutDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedLayoutDelegate?.responds(to: selector) == true {
            return forwardedLayoutDelegate
        }
        return super.forwardingTarget(for: selector)
    }

    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard let backingStore = textContentStorage.attributedString else {
            return nil
        }

        let paragraph = NSMutableAttributedString(
            attributedString: backingStore.attributedSubstring(from: range)
        )
        let fullRange = NSRange(location: 0, length: paragraph.length)
        var containsSuffixAttribute = false
        paragraph.enumerateAttribute(.suffixedAttachment, in: fullRange) { value, _, stop in
            guard value != nil else {
                return
            }
            containsSuffixAttribute = true
            stop.pointee = true
        }
        guard containsSuffixAttribute else {
            return nil
        }

        let suffixSource = NSAttributedString(attributedString: paragraph)

        // Always strip the library attribute, including when a real NSTextAttachment
        // takes presentation precedence. It is metadata for this object, not an
        // attribute TextKit 2 should try to interpret.
        paragraph.removeAttribute(.suffixedAttachment, range: fullRange)

        let suffixGroups = Self.suffixGroups(in: suffixSource)
        // Custom attributes participate in Core Text run segmentation even when Core
        // Text does not render them. Shape the clean presentation paragraph so two
        // suffix objects inside one Arabic ligature cannot split that ligature into
        // artificial one-character clusters.
        let shapingClusters = Self.shapingClusters(in: paragraph)
        let nonzeroRightToLeftGroups = suffixGroups.filter { group in
            group.cluster.isRightToLeft && group.width != 0
        }
        if !nonzeroRightToLeftGroups.isEmpty {
            let allSuffixWidthsByClusterLocation = Dictionary(
                suffixGroups.filter { $0.width != 0 }.map { group in
                    (group.cluster.range.location, group.width)
                },
                uniquingKeysWith: +
            )
            applyRightToLeftPresentation(
                to: paragraph,
                cleanClusters: shapingClusters,
                suffixGroups: nonzeroRightToLeftGroups,
                allSuffixWidthsByClusterLocation: allSuffixWidthsByClusterLocation
            )
        }
        for group in suffixGroups {
            guard group.width != 0, !group.cluster.isRightToLeft else {
                continue
            }

            // A grapheme boundary is not necessarily a shaping boundary. Arabic and
            // Indic text, for example, may map several characters to one glyph cluster;
            // assigning spacing to an interior character is then ignored or breaks shaping.
            // Core Text exposes the string-index clusters produced from the same
            // attributed paragraph. Apply the presentation spacing uniformly across the
            // selected complete cluster so TextKit 2 never sees an interior attribute split.
            // LTR tracking places the added advance visually after its host. RTL is handled
            // above by exact per-cluster font metrics because iOS 18 excludes RTL tracking
            // and kerning from TextKit 2 line width.
            let spacingLocation = group.cluster.range.location
            let spacingRange = group.cluster.range

            // Apple documents that nonzero tracking disables nonessential ligatures
            // unless a ligature attribute is present. UIKit's normal default is enabled
            // even though the attributed string commonly omits the key. Materialize that
            // default before adding tracking or kerning. Keep the presentation attribute
            // on the complete Core Text cluster so it cannot split a surrogate pair,
            // combining sequence, or ligature. Explicit client values remain untouched.
            var rangesMissingLigature = [NSRange]()
            paragraph.enumerateAttribute(.ligature, in: spacingRange) { value, range, _ in
                if value == nil {
                    rangesMissingLigature.append(range)
                }
            }
            for range in rangesMissingLigature {
                paragraph.addAttribute(
                    .ligature,
                    value: NSNumber(value: 1),
                    range: range
                )
            }

            let existingTracking = (paragraph.attribute(
                .tracking,
                at: spacingLocation,
                effectiveRange: nil
            ) as? NSNumber)?.doubleValue ?? 0
            paragraph.addAttribute(
                .tracking,
                value: NSNumber(value: existingTracking + group.width),
                range: spacingRange
            )
        }

        // TextKit requires a custom presentation paragraph to have exactly the same
        // UTF-16 length as the range it represents. Keep this invariant close to the
        // delegate boundary because violating it corrupts NSTextLocation mapping.
        precondition(paragraph.length == range.length)
        return NSTextParagraph(attributedString: paragraph)
    }

    /// Reserves RTL suffix width with one metric carrier per suffix host.
    ///
    /// Candidate soft lines are chosen exactly once from the untouched paragraph. For the
    /// clean line that owns a host, the carrier is calibrated so the complete fixed-range
    /// Core Text line measures `clean width + suffix width`. The presentation line may then
    /// wrap differently, but that result never feeds back into carrier construction. This
    /// makes repeated TextKit layout deterministic at widths near a line-break boundary.
    ///
    /// All RTL glyphs are hidden with one common presentation color and redrawn from the
    /// clean paragraph. Only hosts receive a transformed font, so nonhost soft lines retain
    /// their original contextual metrics instead of becoming one font run per cluster.
    private func applyRightToLeftPresentation(
        to paragraph: NSMutableAttributedString,
        cleanClusters: [ShapingCluster],
        suffixGroups: [SuffixGroup],
        allSuffixWidthsByClusterLocation: [Int: CGFloat]
    ) {
        let suffixWidthByHostLocation = Dictionary(
            suffixGroups.map { group in
                (group.cluster.range.location, group.width)
            },
            uniquingKeysWith: +
        )
        let allRightToLeftClusters = cleanClusters.filter(\.isRightToLeft)
        let hostClusters = allRightToLeftClusters.filter { cluster in
            suffixWidthByHostLocation[cluster.range.location] != nil
        }
        guard !allRightToLeftClusters.isEmpty, !hostClusters.isEmpty else {
            return
        }

        // Capture the clean line plan before adding any presentation-only boundary.
        let cleanTypesetter = CTTypesetterCreateWithAttributedString(paragraph)
        let textContainerWidth = textContainer.map { container in
            container.size.width - 2 * container.lineFragmentPadding
        }
        let containerWidth = availableLayoutWidth
            ?? textContainerWidth.flatMap { $0 > 0 ? $0 : nil }
            ?? .greatestFiniteMagnitude
        let cleanLineRanges = maximumLegalLineRanges(
            in: paragraph,
            typesetter: cleanTypesetter,
            cleanClusters: cleanClusters,
            containerWidth: containerWidth,
            suffixWidthsByClusterLocation: allSuffixWidthsByClusterLocation
        )

        let baseFontByClusterLocation = Dictionary(
            uniqueKeysWithValues: allRightToLeftClusters.map { cluster in
                (cluster.range.location, Self.font(in: paragraph, at: cluster.range.location))
            }
        )

        // A common color hides the complete affected RTL surface without introducing one
        // distinct drawing run per shaping cluster. The clean fragment restores the client
        // colors, stroke, and shadow after TextKit has laid out the transparent carriers.
        for cluster in allRightToLeftClusters {
            materializeLigatureDefault(in: paragraph, range: cluster.range)
            Self.materializeInheritedDecorationColors(
                in: paragraph,
                range: cluster.range
            )
            paragraph.addAttribute(
                .foregroundColor,
                value: UIColor.clear,
                range: cluster.range
            )
            paragraph.removeAttribute(.shadow, range: cluster.range)
            paragraph.removeAttribute(.strokeColor, range: cluster.range)
            paragraph.removeAttribute(.strokeWidth, range: cluster.range)
        }
        for cluster in hostClusters {
            paragraph.addAttribute(
                .font,
                value: Self.horizontallyScaledFont(
                    baseFontByClusterLocation[cluster.range.location]
                        ?? Self.font(in: paragraph, at: cluster.range.location),
                    scale: 1
                ),
                range: cluster.range
            )
        }

        // Calibrate immutable clean ranges only. Usually the suffix host is the sole
        // carrier. If its boundary perturbs a neighboring soft line, that line receives
        // one local normalizer instead of splitting every RTL cluster in the paragraph.
        for cleanLineRange in cleanLineRanges {
            let cleanLine = CTTypesetterCreateLine(
                cleanTypesetter,
                CFRange(
                    location: cleanLineRange.location,
                    length: cleanLineRange.length
                )
            )
            let suffixWidth = suffixWidthByHostLocation.reduce(CGFloat.zero) { result, entry in
                result + (cleanLineRange.contains(entry.key) ? entry.value : 0)
            }
            let desiredWidth = CGFloat(CTLineGetTypographicBounds(
                cleanLine,
                nil,
                nil,
                nil
            )) + suffixWidth
            let currentTypesetter = CTTypesetterCreateWithAttributedString(paragraph)
            let currentLine = CTTypesetterCreateLine(
                currentTypesetter,
                CFRange(
                    location: cleanLineRange.location,
                    length: cleanLineRange.length
                )
            )
            let currentWidth = CGFloat(CTLineGetTypographicBounds(
                currentLine,
                nil,
                nil,
                nil
            ))
            guard abs(currentWidth - desiredWidth) > 0.01 else {
                continue
            }
            let candidates = allRightToLeftClusters.filter { cluster in
                cleanLineRange.contains(cluster.range.location)
            }
            guard let carrier = candidates.first(where: { cluster in
                suffixWidthByHostLocation[cluster.range.location] != nil
            }) ?? candidates.first,
            let baseFont = baseFontByClusterLocation[carrier.range.location] else {
                continue
            }
            func measuredWidth(at scale: CGFloat) -> CGFloat {
                paragraph.addAttribute(
                    .font,
                    value: Self.horizontallyScaledFont(baseFont, scale: scale),
                    range: carrier.range
                )
                let typesetter = CTTypesetterCreateWithAttributedString(paragraph)
                let line = CTTypesetterCreateLine(
                    typesetter,
                    CFRange(
                        location: cleanLineRange.location,
                        length: cleanLineRange.length
                    )
                )
                return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }

            // With an immutable string range and glyph choice, horizontal font-matrix
            // advance is affine in its scale. Measure that slope at 1x and 2x, then use
            // at most two secant corrections for fonts whose contextual boundary makes
            // the first estimate slightly nonlinear. Typical lines require three CTLines
            // instead of a 24-step binary search over the complete paragraph.
            var previousScale = CGFloat(1)
            var previousWidth = currentWidth
            var scale = CGFloat(2)
            var widthAtScale = measuredWidth(at: scale)
            var bestScale = previousScale
            var bestError = abs(previousWidth - desiredWidth)
            if abs(widthAtScale - desiredWidth) < bestError {
                bestScale = scale
                bestError = abs(widthAtScale - desiredWidth)
            }
            for _ in 0..<2 {
                let slope = (widthAtScale - previousWidth) / (scale - previousScale)
                guard slope.isFinite, abs(slope) > 0.0001 else {
                    break
                }
                let correctedScale = scale + (desiredWidth - widthAtScale) / slope
                guard correctedScale.isFinite, correctedScale > 0 else {
                    break
                }
                previousScale = scale
                previousWidth = widthAtScale
                scale = correctedScale
                widthAtScale = measuredWidth(at: scale)
                let error = abs(widthAtScale - desiredWidth)
                if error < bestError {
                    bestScale = scale
                    bestError = error
                }
                if error <= 0.01 {
                    break
                }
            }
            if scale != bestScale {
                _ = measuredWidth(at: bestScale)
            }
        }
    }

    /// Chooses the farthest clean line endpoint whose visible width fits every suffix.
    ///
    /// Each line starts with Core Text's normal full-width endpoint. Candidate shaping
    /// boundaries are then inspected from farthest to nearest. A candidate is accepted only
    /// when Core Text selects the same contextual endpoint at that candidate's clean width
    /// and the visible width, excluding hanging trailing whitespace, plus every suffix in
    /// the range fits the paragraph's effective line width. The output depends only on the
    /// clean paragraph, never on a realized TextKit presentation line.
    private func maximumLegalLineRanges(
        in cleanParagraph: NSAttributedString,
        typesetter: CTTypesetter,
        cleanClusters: [ShapingCluster],
        containerWidth: CGFloat,
        suffixWidthsByClusterLocation: [Int: CGFloat]
    ) -> [NSRange] {
        let stringLength = cleanParagraph.length
        guard stringLength > 0 else {
            return []
        }
        guard containerWidth.isFinite, containerWidth > 0 else {
            return [NSRange(location: 0, length: stringLength)]
        }

        var endpoints = Set(cleanClusters.map(\.range.upperBound))
        let string = cleanParagraph.string
        string.enumerateSubstrings(
            in: string.startIndex..<string.endIndex,
            options: .byComposedCharacterSequences
        ) { _, range, _, _ in
            endpoints.insert(NSRange(range, in: string).upperBound)
        }
        endpoints.insert(stringLength)

        var location = 0
        var ranges = [NSRange]()
        var isFirstLine = true
        while location < stringLength {
            let paragraphStyle = cleanParagraph.attribute(
                .paragraphStyle,
                at: min(location, stringLength - 1),
                effectiveRange: nil
            ) as? NSParagraphStyle
            // An absent paragraph style has UIKit's documented default word-wrapping
            // semantics. `NSTextContainer.lineBreakMode` governs the container's final
            // visible line; it does not replace paragraph wrapping for ordinary lines.
            // Only an explicit paragraph style opts in to character-boundary planning.
            let usesClusterBreak = paragraphStyle?.lineBreakMode == .byCharWrapping
            let effectiveWidth = Self.effectiveLineWidth(
                containerWidth: containerWidth,
                paragraphStyle: paragraphStyle,
                isFirstLine: isFirstLine
            )
            let suggestedLength = usesClusterBreak
                ? CTTypesetterSuggestClusterBreak(typesetter, location, effectiveWidth)
                : CTTypesetterSuggestLineBreak(typesetter, location, effectiveWidth)
            let initialLength = max(
                1,
                min(
                    suggestedLength,
                    stringLength - location
                )
            )
            let initialEnd = location + initialLength
            let candidateEnds = endpoints.filter { endpoint in
                endpoint > location && endpoint <= initialEnd
            }.sorted(by: >)
            let selectedEnd = candidateEnds.first { endpoint in
                let range = NSRange(location: location, length: endpoint - location)
                let line = CTTypesetterCreateLine(
                    typesetter,
                    CFRange(location: range.location, length: range.length)
                )
                let typographicWidth = CGFloat(CTLineGetTypographicBounds(
                    line,
                    nil,
                    nil,
                    nil
                ))
                let visibleWidth = typographicWidth
                    - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                let suffixWidth = suffixWidthsByClusterLocation.reduce(CGFloat.zero) { result, entry in
                    result + (range.contains(entry.key) ? entry.value : 0)
                }
                guard visibleWidth + suffixWidth <= effectiveWidth + 0.001 else {
                    return false
                }
                let legalLength = usesClusterBreak
                    ? CTTypesetterSuggestClusterBreak(
                        typesetter,
                        location,
                        typographicWidth + 0.01
                    )
                    : CTTypesetterSuggestLineBreak(
                        typesetter,
                        location,
                        typographicWidth + 0.01
                    )
                return legalLength == range.length
            } ?? candidateEnds.last ?? min(stringLength, location + 1)
            let length = max(1, selectedEnd - location)
            ranges.append(NSRange(location: location, length: length))
            location += length
            isFirstLine = false
        }
        return ranges
    }

    /// Returns the inline width after applying first/subsequent and tail indents.
    private static func effectiveLineWidth(
        containerWidth: CGFloat,
        paragraphStyle: NSParagraphStyle?,
        isFirstLine: Bool
    ) -> CGFloat {
        guard let paragraphStyle else {
            return containerWidth
        }
        let headIndent = isFirstLine
            ? paragraphStyle.firstLineHeadIndent
            : paragraphStyle.headIndent
        let tailPosition = paragraphStyle.tailIndent > 0
            ? min(containerWidth, paragraphStyle.tailIndent)
            : containerWidth + paragraphStyle.tailIndent
        return max(0.001, tailPosition - headIndent)
    }

    /// Materializes UIKit's implicit ligature-on default before splitting a shaping run.
    ///
    /// Apple documents that nonzero tracking disables nonessential ligatures when the
    /// attribute is absent. RTL uses a font matrix rather than tracking, but preserving the
    /// explicit default keeps shaping deterministic across the two presentation routes and
    /// honors a client's existing `.ligature` value.
    private func materializeLigatureDefault(
        in paragraph: NSMutableAttributedString,
        range: NSRange
    ) {
        var missingRanges = [NSRange]()
        paragraph.enumerateAttribute(.ligature, in: range) { value, range, _ in
            if value == nil {
                missingRanges.append(range)
            }
        }
        for missingRange in missingRanges {
            paragraph.addAttribute(
                .ligature,
                value: NSNumber(value: 1),
                range: missingRange
            )
        }
    }

    /// Creates a font whose horizontal metrics are scaled while vertical metrics remain.
    ///
    /// `CTFontCreateCopyWithAttributes` accepts an explicit transform for the copied font.
    /// Scaling only the horizontal component preserves ascent, descent, and line height.
    private static func horizontallyScaledFont(_ font: UIFont, scale: CGFloat) -> UIFont {
        var matrix = CGAffineTransform(scaleX: scale, y: 1)
        let transformed = CTFontCreateCopyWithAttributes(
            font as CTFont,
            0,
            &matrix,
            nil
        )
        // UIKit and Core Text toll-free bridge their platform font objects. Creating the
        // transformed copy through Core Text is important on Mac Catalyst, where the
        // UIKit font-descriptor matrix helper is unavailable.
        return transformed as UIFont
    }

    /// Returns a visually clear color that remains distinct at an attribute boundary.
    ///
    /// Alpha is zero for every carrier, so the RGB payload never reaches the screen. The
    /// varying payload exists only to prevent adjacent attributed runs from being merged.
    private static func transparentBoundaryColor(at index: Int, count: Int) -> UIColor {
        let component = CGFloat(index + 1) / CGFloat(count + 1)
        return UIColor(
            red: component,
            green: 1 - component,
            blue: 0.5,
            alpha: 0
        )
    }

    /// Returns the effective UIKit font, matching UIKit's normal fallback behavior.
    private static func font(in string: NSAttributedString, at location: Int) -> UIFont {
        string.attribute(.font, at: location, effectiveRange: nil) as? UIFont
            ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
    }

    /// Freezes default decoration colors before an RTL metric carrier becomes transparent.
    ///
    /// UIKit draws an underline or strikethrough without an explicit color using the
    /// run's foreground color. Replacing that foreground with `.clear` would also make the
    /// native decoration disappear. Copy the clean value only where a visible decoration
    /// has no client-supplied color; storing the original color object preserves dynamic
    /// `UIColor` resolution for the view's current trait environment.
    private static func materializeInheritedDecorationColors(
        in string: NSMutableAttributedString,
        range: NSRange
    ) {
        let decorationKeys: [(
            style: NSAttributedString.Key,
            color: NSAttributedString.Key
        )] = [
            (.underlineStyle, .underlineColor),
            (.strikethroughStyle, .strikethroughColor)
        ]

        for keys in decorationKeys {
            var inheritedColors = [(range: NSRange, color: Any)]()
            string.enumerateAttributes(in: range) { attributes, attributeRange, _ in
                guard let style = attributes[keys.style] as? NSNumber,
                      style.intValue != 0,
                      attributes[keys.color] == nil,
                      let foregroundColor = attributes[.foregroundColor] else {
                    return
                }
                inheritedColors.append((attributeRange, foregroundColor))
            }
            for inheritedColor in inheritedColors {
                string.addAttribute(
                    keys.color,
                    value: inheritedColor.color,
                    range: inheritedColor.range
                )
            }
        }
    }

    /// Preserves default decoration colors in UIKit's forwarded rendering attributes.
    ///
    /// Link attributes are supplied after the presentation paragraph is built, so the
    /// attributed-string pass above cannot see them. Copy the forwarded foreground object
    /// before the delegate replaces it with `.clear`; in particular, do not resolve a
    /// dynamic `UIColor` against a trait collection here.
    private static func materializeInheritedDecorationColors(
        in attributes: inout [NSAttributedString.Key: Any]
    ) {
        guard let foregroundColor = attributes[.foregroundColor] else {
            return
        }
        let decorationKeys: [(
            style: NSAttributedString.Key,
            color: NSAttributedString.Key
        )] = [
            (.underlineStyle, .underlineColor),
            (.strikethroughStyle, .strikethroughColor)
        ]
        for keys in decorationKeys {
            guard let style = attributes[keys.style] as? NSNumber,
                  style.intValue != 0,
                  attributes[keys.color] == nil else {
                continue
            }
            attributes[keys.color] = foregroundColor
        }
    }

    // MARK: - NSTextLayoutManagerDelegate

    /// Preserves UIKit's link policy while keeping transformed RTL carriers invisible.
    ///
    /// Link rendering attributes have higher priority than the paragraph's foreground
    /// color. Without this interception, UITextView replaces the carrier's transparent
    /// color with `linkTextAttributes` and draws the horizontally distorted glyph before
    /// the custom fragment restores the clean glyph. The clean fragment snapshot receives
    /// the forwarded link attributes separately, so only the metric carrier is cleared.
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        renderingAttributesForLink link: Any,
        at location: any NSTextLocation,
        defaultAttributes renderingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any]? {
        let forwardedAttributes = forwardedLayoutDelegate?.textLayoutManager?(
            textLayoutManager,
            renderingAttributesForLink: link,
            at: location,
            defaultAttributes: renderingAttributes
        )
        guard isRightToLeftCarrier(at: location, in: textLayoutManager) else {
            return forwardedAttributes
        }

        var attributes = forwardedAttributes ?? renderingAttributes
        Self.materializeInheritedDecorationColors(in: &attributes)
        attributes[.foregroundColor] = UIColor.clear
        attributes[.strokeColor] = UIColor.clear
        attributes[.strokeWidth] = NSNumber(value: 0)
        // NSTextLayoutManager's rendering-attribute contract gives NSNull special
        // removal semantics. This is intentionally different from the backing
        // attributed-string value contract for `.shadow`, which normally expects NSShadow.
        attributes[.shadow] = NSNull()
        return attributes
    }

    /// Gives TextKit 2 a fragment that can restore transparent RTL presentation glyphs.
    ///
    /// Returning the stock fragment for unaffected paragraphs would be equivalent, but the
    /// content delegate only creates custom paragraphs when a suffix exists. This keeps the
    /// layout-manager delegate simple and ensures the drawing snapshot is always aligned to
    /// the text element's equal-length UTF-16 range.
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        guard let drawingParagraph = drawingParagraph(
            for: textElement,
            in: textLayoutManager
        ), !drawingParagraph.suffixWidthsByClusterLocation.isEmpty else {
            if let forwardedFragment = forwardedLayoutDelegate?.textLayoutManager?(
                textLayoutManager,
                textLayoutFragmentFor: location,
                in: textElement
            ) {
                return forwardedFragment
            }
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
        return TextKit2SuffixLayoutFragment(
            textElement: textElement,
            drawingParagraph: drawingParagraph
        )
    }

    /// Captures the clean backing paragraph and maps suffix widths to local RTL clusters.
    ///
    /// `NSTextLayoutManagerDelegate` receives an abstract element and location rather than
    /// an `NSRange`. The content manager is the authoritative TextKit 2 converter between
    /// that location space and the backing UTF-16 coordinate space. The presentation and
    /// backing paragraphs have equal length, so the resulting local ranges are one-to-one.
    private func drawingParagraph(
        for textElement: NSTextElement,
        in textLayoutManager: NSTextLayoutManager
    ) -> DrawingParagraph? {
        guard let textContentManager = textLayoutManager.textContentManager,
              let textContentStorage = textContentManager as? NSTextContentStorage,
              let backingStore = textContentStorage.attributedString,
              let elementRange = textElement.elementRange else {
            return nil
        }
        let documentStart = textContentManager.documentRange.location
        let elementStart = textContentManager.offset(
            from: documentStart,
            to: elementRange.location
        )
        let elementEnd = textContentManager.offset(
            from: documentStart,
            to: elementRange.endLocation
        )
        let documentRange = NSRange(
            location: elementStart,
            length: max(0, elementEnd - elementStart)
        )
        guard documentRange.length > 0,
              documentRange.upperBound <= backingStore.length else {
            return nil
        }

        let cleanParagraph = NSMutableAttributedString(
            attributedString: backingStore.attributedSubstring(from: documentRange)
        )
        cleanParagraph.removeAttribute(
            .suffixedAttachment,
            range: NSRange(location: 0, length: cleanParagraph.length)
        )
        applyForwardedLinkRenderingAttributes(
            to: cleanParagraph,
            elementRange: elementRange,
            textContentManager: textContentManager,
            textLayoutManager: textLayoutManager
        )
        let suffixGroups = Self.suffixGroups(in: backingStore, range: documentRange)
        var widthsByLocalLocation = [Int: CGFloat]()
        for group in suffixGroups where group.cluster.isRightToLeft && group.width != 0 {
            let localLocation = group.cluster.range.location - documentRange.location
            guard localLocation >= 0, localLocation < cleanParagraph.length else {
                continue
            }
            widthsByLocalLocation[localLocation, default: 0] += group.width
        }
        guard !widthsByLocalLocation.isEmpty else {
            return nil
        }
        return DrawingParagraph(
            documentRange: documentRange,
            cleanAttributedString: cleanParagraph,
            suffixWidthsByClusterLocation: widthsByLocalLocation
        )
    }

    /// Returns whether a document location is represented by a transformed RTL carrier.
    ///
    /// The backing store deliberately has no private marker attribute. Reconstructing the
    /// affected paragraph from its public suffix metadata keeps the position space honest
    /// and limits this work to link callbacks, which occur once per rendered link run.
    private func isRightToLeftCarrier(
        at location: any NSTextLocation,
        in textLayoutManager: NSTextLayoutManager
    ) -> Bool {
        guard let textContentManager = textLayoutManager.textContentManager,
              let textContentStorage = textContentManager as? NSTextContentStorage,
              let backingStore = textContentStorage.attributedString,
              backingStore.length > 0 else {
            return false
        }
        let documentLocation = textContentManager.offset(
            from: textContentManager.documentRange.location,
            to: location
        )
        guard documentLocation >= 0, documentLocation < backingStore.length else {
            return false
        }
        let paragraphRange = (backingStore.string as NSString).paragraphRange(
            for: NSRange(location: documentLocation, length: 0)
        )
        let suffixGroups = Self.suffixGroups(in: backingStore, range: paragraphRange)
        guard suffixGroups.contains(where: { group in
            group.cluster.isRightToLeft && group.width != 0
        }) else {
            return false
        }

        let paragraph = NSMutableAttributedString(
            attributedString: backingStore.attributedSubstring(from: paragraphRange)
        )
        paragraph.removeAttribute(
            .suffixedAttachment,
            range: NSRange(location: 0, length: paragraph.length)
        )
        let localLocation = documentLocation - paragraphRange.location
        return Self.shapingClusters(in: paragraph).contains { cluster in
            cluster.isRightToLeft && NSLocationInRange(localLocation, cluster.range)
        }
    }

    /// Materializes UIKit's forwarded link colors in the clean custom-draw snapshot.
    ///
    /// Core Text does not interpret `.link` by itself. UITextView's private layout
    /// controller turns it into rendering attributes such as `linkTextAttributes`; the
    /// custom fragment must ask that same controller and apply the result before `CTRunDraw`
    /// restores undistorted glyphs. Surface-only decorations are still left to `super.draw`.
    private func applyForwardedLinkRenderingAttributes(
        to paragraph: NSMutableAttributedString,
        elementRange: NSTextRange,
        textContentManager: NSTextContentManager,
        textLayoutManager: NSTextLayoutManager
    ) {
        let fullRange = NSRange(location: 0, length: paragraph.length)
        paragraph.enumerateAttribute(.link, in: fullRange) { link, range, _ in
            guard let link,
                  let location = textContentManager.location(
                      elementRange.location,
                      offsetBy: range.location
                  ) else {
                return
            }
            let defaults = paragraph.attributes(at: range.location, effectiveRange: nil)
            guard let attributes = forwardedLayoutDelegate?.textLayoutManager?(
                textLayoutManager,
                renderingAttributesForLink: link,
                at: location,
                defaultAttributes: defaults
            ) else {
                return
            }
            for (key, value) in attributes {
                if value is NSNull {
                    paragraph.removeAttribute(key, range: range)
                } else {
                    paragraph.addAttribute(key, value: value, range: range)
                }
            }
        }
    }

    /**
     Positions every currently laid-out suffix in the text view's content surface.

     The method is intentionally derived from the current backing attributes on every
     view layout pass. TextKit 2 lays out viewport fragments lazily, and text editing can
     invalidate them at any time; keeping a second range cache would easily become stale.
     */
    func layoutSuffixes(in textView: UITextView) {
        guard let textLayoutManager = textView.textLayoutManager else {
            assertionFailure("Suffix presentation requires TextKit 2")
            return
        }
        guard let textContentManager = textLayoutManager.textContentManager else {
            assertionFailure("Suffix presentation requires a TextKit 2 content manager")
            return
        }

        // Ask TextKit 2 to materialize only the viewport. Forcing layout of documentRange
        // here would defeat viewport-based layout and turn every scroll/layout pass into
        // work proportional to the entire document.
        textLayoutManager.textViewportLayoutController.layoutViewport()

        let backingStore = textView.textStorage
        let suffixRange = viewportRange(
            in: backingStore,
            textContentManager: textContentManager,
            textLayoutManager: textLayoutManager
        )
        var activeImageKeys = Set<ImageKey>()
        let laidOutLines = Self.laidOutLines(in: textLayoutManager)
        let suffixGroups = Self.suffixGroups(in: backingStore, range: suffixRange)
        for group in suffixGroups {
            guard let groupFrame = suffixGroupFrame(
                for: group,
                in: laidOutLines,
                textView: textView
            ) else {
                continue
            }
            var inlineOffset: CGFloat = 0
            for entry in group.entries {
                let suffix = entry.suffix
                let suffixFrame: CGRect
                if group.cluster.isRightToLeft {
                    suffixFrame = CGRect(
                        x: groupFrame.maxX - inlineOffset - suffix.size.width,
                        y: groupFrame.minY,
                        width: suffix.size.width,
                        height: suffix.size.height
                    )
                } else {
                    suffixFrame = CGRect(
                        x: groupFrame.minX + inlineOffset,
                        y: groupFrame.minY,
                        width: suffix.size.width,
                        height: suffix.size.height
                    )
                }
                inlineOffset += suffix.size.width

                switch suffix.attachment {
                case .image(let image):
                    let key = ImageKey(
                        location: entry.characterRange.location,
                        suffix: ObjectIdentifier(suffix)
                    )
                    activeImageKeys.insert(key)
                    let imageView: UIImageView
                    if let existingImageView = self.imageViews[key] {
                        imageView = existingImageView
                    } else {
                        imageView = UIImageView(image: image)
                        imageView.isAccessibilityElement = false
                        imageView.isUserInteractionEnabled = false

                        // `textInputView` is the public content surface exposed by
                        // `TextEditorView.textContentView`; it scrolls together with text.
                        textView.textInputView.addSubview(imageView)
                        self.imageViews[key] = imageView
                    }
                    imageView.image = image

                    // `suffixFrame` uses text-container coordinates for compatibility with
                    // the public view-attachment closure. UIKit subviews, however, use the
                    // inset content-view coordinate space, so add the insets back here.
                    imageView.frame = suffixFrame.offsetBy(
                        dx: textView.textContainerInset.left,
                        dy: textView.textContainerInset.top
                    )
                    imageView.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor
                    imageView.layer.borderWidth = Configuration.shared.isDebugTextLayoutEnabled ? 1 : 0

                case let .view(view, layoutInTextContainer):
                    layoutInTextContainer(view, suffixFrame)
                }
            }
        }

        // Presentation attributes can disappear asynchronously. Remove image views that
        // were not observed in this pass so stale suffixes never survive a text update.
        let obsoleteImageKeys = imageViews.keys.filter { key in
            !activeImageKeys.contains(key)
        }
        for key in obsoleteImageKeys {
            imageViews.removeValue(forKey: key)?.removeFromSuperview()
        }
    }

    /// Enumerates one suffix per composed character sequence.
    ///
    /// `NSAttributedString` ranges are UTF-16 based, while Swift `Character` boundaries
    /// protect emoji, combining marks, and other multi-code-unit graphemes from being
    /// split. A real `.attachment` wins because TextKit already owns its presentation.
    private static func enumerateSuffixes(
        in attributedString: NSAttributedString,
        range requestedRange: NSRange? = nil,
        using body: @escaping (_ characterRange: NSRange,
                               _ suffix: TextAttributes.SuffixedAttachment) -> Void
    ) {
        let string = attributedString.string
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let requestedRange = NSIntersectionRange(requestedRange ?? fullRange, fullRange)
        guard requestedRange.length > 0 else {
            return
        }
        let composedRange = (string as NSString).rangeOfComposedCharacterSequences(
            for: requestedRange
        )
        guard let substringRange = Range(composedRange, in: string) else {
            return
        }
        string.enumerateSubstrings(
            in: substringRange,
            options: .byComposedCharacterSequences
        ) { _, substringRange, _, _ in
            let characterRange = NSRange(substringRange, in: string)
            var suffix: TextAttributes.SuffixedAttachment?
            var containsTextAttachment = false
            attributedString.enumerateAttributes(in: characterRange) { attributes, _, stop in
                if suffix == nil {
                    suffix = attributes[.suffixedAttachment]
                        as? TextAttributes.SuffixedAttachment
                }
                if attributes[.attachment] != nil {
                    containsTextAttachment = true
                }
                if suffix != nil, containsTextAttachment {
                    stop.pointee = true
                }
            }
            guard let suffix, !containsTextAttachment else {
                return
            }
            body(characterRange, suffix)
        }
    }

    /// Converts TextKit 2's laid-out viewport to the backing store's UTF-16 range.
    ///
    /// A nil viewport is normal before a text view enters a window. Falling back to the
    /// complete range keeps offscreen sizing and unit-test layout deterministic; once a
    /// viewport exists, scrolling work stays bounded to its laid-out text.
    private func viewportRange(
        in backingStore: NSAttributedString,
        textContentManager: NSTextContentManager,
        textLayoutManager: NSTextLayoutManager
    ) -> NSRange {
        guard let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange else {
            return NSRange(location: 0, length: backingStore.length)
        }

        let documentStart = textContentManager.documentRange.location
        let location = textContentManager.offset(
            from: documentStart,
            to: viewportRange.location
        )
        let end = textContentManager.offset(
            from: documentStart,
            to: viewportRange.endLocation
        )
        let fullRange = NSRange(location: 0, length: backingStore.length)
        return NSIntersectionRange(
            NSRange(location: location, length: max(0, end - location)),
            fullRange
        )
    }

    /// Returns logical UTF-16 ranges for the shaping clusters in one paragraph.
    ///
    /// `CTRun` glyph indices are in visual order, which is reversed for RTL runs. Sorting
    /// their string indices and adding the run boundaries reconstructs stable logical
    /// cluster ranges without depending on private glyph APIs from TextKit.
    private static func shapingClusters(in attributedString: NSAttributedString) -> [ShapingCluster] {
        let line = CTLineCreateWithAttributedString(attributedString)
        return coreTextClusterMetrics(
            in: line,
            attributedString: attributedString
        ).map { cluster in
            ShapingCluster(
                range: cluster.range,
                isRightToLeft: cluster.isRightToLeft,
                advance: cluster.advance,
                usesCaretAdvance: cluster.usesCaretAdvance
            )
        }
    }

    /// Groups public suffixes by the shaping cluster that TextKit lays out atomically.
    ///
    /// Several graphemes can collapse into one Arabic or Indic cluster. Reserving width
    /// once per suffix at the same spacing carrier produces an ambiguous gap and overlapping
    /// overlays. Aggregating first gives the cluster one deterministic gap whose children
    /// can then be tiled in logical UTF-16 order.
    private static func suffixGroups(
        in attributedString: NSAttributedString,
        range: NSRange? = nil
    ) -> [SuffixGroup] {
        var entries = [SuffixEntry]()
        enumerateSuffixes(in: attributedString, range: range) { characterRange, suffix in
            entries.append(
                SuffixEntry(characterRange: characterRange, suffix: suffix)
            )
        }

        // NSTextContentStorage supplies one attributed string per paragraph, while the
        // backing NSTextStorage is document-wide. Core Text cluster indices are relative
        // to the string passed to it, so shape only paragraphs that contain suffixes and
        // translate their local cluster ranges back into document UTF-16 coordinates.
        // Besides fixing multi-paragraph lookup, this keeps viewport layout proportional
        // to the visible paragraphs instead of shaping the entire document on every scroll.
        let string = attributedString.string as NSString
        let paragraphRanges = Set(entries.map { entry in
            string.paragraphRange(for: NSRange(location: entry.characterRange.location, length: 0))
        }).sorted { lhs, rhs in
            lhs.location < rhs.location
        }
        var clusters = [ShapingCluster]()
        for paragraphRange in paragraphRanges {
            let paragraph = NSMutableAttributedString(
                attributedString: attributedString.attributedSubstring(from: paragraphRange)
            )
            paragraph.removeAttribute(
                .suffixedAttachment,
                range: NSRange(location: 0, length: paragraph.length)
            )
            clusters.append(contentsOf: shapingClusters(in: paragraph).map { cluster in
                ShapingCluster(
                    range: NSRange(
                        location: paragraphRange.location + cluster.range.location,
                        length: cluster.range.length
                    ),
                    isRightToLeft: cluster.isRightToLeft,
                    advance: cluster.advance,
                    usesCaretAdvance: cluster.usesCaretAdvance
                )
            })
        }

        var entriesByCluster = [Int: [SuffixEntry]]()
        for entry in entries {
            guard let clusterIndex = clusters.firstIndex(where: { cluster in
                NSIntersectionRange(cluster.range, entry.characterRange).length > 0
            }) else {
                continue
            }
            entriesByCluster[clusterIndex, default: []].append(entry)
        }

        return entriesByCluster.keys.sorted().map { clusterIndex in
            SuffixGroup(
                cluster: clusters[clusterIndex],
                entries: entriesByCluster[clusterIndex, default: []].sorted { lhs, rhs in
                    lhs.characterRange.location < rhs.characterRange.location
                }
            )
        }
    }

    /// Captures every TextKit 2 line currently available in the viewport.
    private static func laidOutLines(
        in textLayoutManager: NSTextLayoutManager
    ) -> [LaidOutLine] {
        guard let textContentManager = textLayoutManager.textContentManager else {
            return []
        }
        var result = [LaidOutLine]()
        let enumerationStart = textLayoutManager.textViewportLayoutController
            .viewportRange?.location ?? textContentManager.documentRange.location
        textLayoutManager.enumerateTextLayoutFragments(
            from: enumerationStart,
            options: []
        ) { fragment in
            guard fragment.state == .layoutAvailable else {
                return true
            }
            guard let elementRange = fragment.textElement?.elementRange else {
                return true
            }
            let elementStart = textContentManager.offset(
                from: textContentManager.documentRange.location,
                to: elementRange.location
            )
            for line in fragment.textLineFragments {
                result.append(
                    LaidOutLine(
                        line: line,
                        // NSTextLineFragment.characterRange indexes its paragraph-local
                        // attributedString. Convert it to the backing store's document
                        // coordinates before comparing it with public suffix ranges.
                        characterRange: NSRange(
                            location: elementStart + line.characterRange.location,
                            length: line.characterRange.length
                        ),
                        origin: fragment.layoutFragmentFrame.origin
                    )
                )
            }
            return true
        }
        return result
    }

    /// Returns whether a shaping cluster contains only a paragraph terminator.
    ///
    /// Core Text can expose the newline as a zero-glyph logical cluster. Tracking it is
    /// trailing whitespace, while kerning it has no printable pair; neither reserves a
    /// stable inline box for a suffix immediately before the newline. Such a host is
    /// terminal for our purposes.
    private static func isParagraphTerminator(at range: NSRange, in string: String) -> Bool {
        let terminators = CharacterSet.newlines
        let substring = (string as NSString).substring(with: range)
        return !substring.isEmpty && substring.unicodeScalars.allSatisfy { scalar in
            terminators.contains(scalar)
        }
    }

    /// Returns the actual presentation-spacing gap for a cluster in TextKit's visual line.
    ///
    /// `UITextInput.caretRect` is unsuitable after a suffix itself causes wrapping: the
    /// logical end position can move to the next line even though the host cluster stays
    /// on the previous one. `NSTextLineFragment.characterRange` identifies the true host
    /// line; its typographic edge supplies the gap at a line end, while the caret remains
    /// useful as the centre of an interior spaced pair.
    private func suffixGroupFrame(
        for group: SuffixGroup,
        in laidOutLines: [LaidOutLine],
        textView: UITextView
    ) -> CGRect? {
        guard let laidOutLine = laidOutLines.first(where: { candidate in
            candidate.characterRange.contains(group.cluster.range.location)
        }) else {
            return nil
        }

        let line = laidOutLine.line
        let lineFrame = line.typographicBounds.offsetBy(
            dx: laidOutLine.origin.x,
            dy: laidOutLine.origin.y
        )
        if group.cluster.isRightToLeft {
            // The RTL presentation carrier is the host cluster itself, and its visual box
            // is exactly `cleanAdvance + suffixWidth`. The custom fragment draws the clean
            // host at the carrier's right-hand portion, so the suffix gap is the carrier's
            // visual-left `group.width` points. Reading that box from the actual TextKit 2
            // line remains correct at interior bidi boundaries, hard paragraph endings,
            // and soft wraps without a second layout probe or a backing attribute edit.
            let localClusterRange = NSRange(
                location: group.cluster.range.location
                    - laidOutLine.characterRange.location
                    + line.characterRange.location,
                length: group.cluster.range.length
            )
            guard let carrierBounds = TextKit2SuffixLayoutFragment.visualBounds(
                of: localClusterRange,
                in: line.attributedString
            ) else {
                return nil
            }
            let endsVisualLine = group.cluster.range.upperBound
                == laidOutLine.characterRange.upperBound
            let paragraphRange = (textView.textStorage.string as NSString).paragraphRange(
                for: NSRange(location: group.cluster.range.location, length: 0)
            )
            let isSoftWrappedHost = endsVisualLine
                && group.cluster.range.upperBound < paragraphRange.upperBound
            let carrierMinimumX: CGFloat
            if isSoftWrappedHost {
                // A soft-wrapped RTL line is right-aligned in its text container. Core
                // Text offsets are relative to the shaped substring, whereas TextKit's
                // typographic bounds already contain that alignment. The carrier owns the
                // entire visible line in this branch, so its visual-left edge is the line
                // edge itself. This also avoids the downstream caret that TextKit reports
                // on the following line for the same logical boundary.
                carrierMinimumX = 0
            } else {
                carrierMinimumX = carrierBounds.minX
            }
            return CGRect(
                x: isSoftWrappedHost
                    ? 0
                    : laidOutLine.origin.x
                        + line.typographicBounds.minX
                        + carrierMinimumX,
                y: lineFrame.minY,
                width: group.width,
                height: 0
            )
        }

        let x: CGFloat
        let trailingRange = NSRange(
            location: group.cluster.range.upperBound,
            length: max(
                0,
                laidOutLine.characterRange.upperBound - group.cluster.range.upperBound
            )
        )
        let endsVisualLine = trailingRange.length == 0
            || Self.isParagraphTerminator(at: trailingRange, in: textView.textStorage.string)
        if endsVisualLine {
            // At a soft-wrap boundary UIKit reports the logical downstream caret on the
            // following line, so the line's typographic edge is the stable LTR source.
            x = lineFrame.maxX - group.width
        } else {
            // For an interior pair, locationForCharacter and caretRect expose the centre
            // of the spaced pair, not either edge of the inserted space. Centre the whole
            // aggregated group on that boundary, then tile its children without asking
            // TextKit for impossible caret positions inside one shaping cluster.
            guard let position = textView.position(
                from: textView.beginningOfDocument,
                offset: group.cluster.range.upperBound
            ) else {
                return nil
            }
            let caret = textView.caretRect(for: position)
            let boundary = caret.midX - textView.textContainerInset.left
            x = boundary - group.width / 2
        }
        return CGRect(
            x: x,
            y: lineFrame.minY,
            width: group.width,
            height: 0
        )
    }
}

/**
 A TextKit 2 layout fragment that restores clean contextual RTL glyphs over transparent
 metric carriers.

 The base fragment remains responsible for backgrounds, selections, underlines,
 strikethroughs, native attachments, and every unaffected glyph. Only RTL runs in a
 paragraph that owns a nonzero suffix are transparent in the presentation string. After
 `super.draw(at:in:)`, this fragment shapes the corresponding clean backing line with Core
 Text, copies the original glyph IDs and font/color attributes, and places each cluster into
 the exact visual box measured from the presentation line.

 Per-cluster placement matters for mixed bidirectional text: aligning a complete clean line
 to one edge would move adjacent Latin runs and cannot represent an interior suffix gap. It
 also preserves Arabic contextual forms because glyph IDs come from the clean full line,
 not from isolated substrings.
 */
private final class TextKit2SuffixLayoutFragment: NSTextLayoutFragment {
    private let drawingParagraph: TextKit2SuffixPresentation.DrawingParagraph

    init(
        textElement: NSTextElement,
        drawingParagraph: TextKit2SuffixPresentation.DrawingParagraph
    ) {
        self.drawingParagraph = drawingParagraph
        super.init(textElement: textElement, range: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        // Draw all native TextKit 2 surfaces first. Affected RTL glyphs have clear
        // foreground, shadow, and stroke in the presentation paragraph, so this does not
        // duplicate their outlines; underline/strikethrough/background remain native.
        super.draw(at: point, in: context)

        // Shape every realized TextKit line as an exact range of the complete clean
        // paragraph. Creating an attributed substring here would discard the neighboring
        // Arabic context at a soft-wrap boundary and select different glyph forms.
        let glyphOnlyParagraph = NSMutableAttributedString(
            attributedString: drawingParagraph.cleanAttributedString
        )
        let glyphOnlyParagraphRange = NSRange(
            location: 0,
            length: glyphOnlyParagraph.length
        )
        glyphOnlyParagraph.removeAttribute(.backgroundColor, range: glyphOnlyParagraphRange)
        glyphOnlyParagraph.removeAttribute(.underlineStyle, range: glyphOnlyParagraphRange)
        glyphOnlyParagraph.removeAttribute(.underlineColor, range: glyphOnlyParagraphRange)
        glyphOnlyParagraph.removeAttribute(.strikethroughStyle, range: glyphOnlyParagraphRange)
        glyphOnlyParagraph.removeAttribute(.strikethroughColor, range: glyphOnlyParagraphRange)
        let cleanTypesetter = CTTypesetterCreateWithAttributedString(glyphOnlyParagraph)

        for lineFragment in textLineFragments where lineFragment.characterRange.length > 0 {
            let lineRange = lineFragment.characterRange
            guard lineRange.upperBound <= drawingParagraph.cleanAttributedString.length,
                  lineRange.upperBound <= lineFragment.attributedString.length else {
                continue
            }
            let cleanCoreTextLine = CTTypesetterCreateLine(
                cleanTypesetter,
                CFRange(location: lineRange.location, length: lineRange.length)
            )
            drawRightToLeftClusters(
                in: cleanCoreTextLine,
                cleanParagraph: glyphOnlyParagraph,
                lineRangeInParagraph: lineRange,
                lineFragment: lineFragment,
                fragmentOrigin: point,
                context: context
            )
        }
    }

    /// Draws affected glyphs from the clean paragraph's exact contextual line.
    ///
    /// Core Text positions are measured from the clean line and therefore include the
    /// script's contextual shaping. A suffix adds blank space immediately to its host's
    /// visual left, so clusters at or to the visual right of that host are translated by
    /// the accumulated suffix widths without scaling their outlines.
    private func drawRightToLeftClusters(
        in cleanCoreTextLine: CTLine,
        cleanParagraph: NSAttributedString,
        lineRangeInParagraph: NSRange,
        lineFragment: NSTextLineFragment,
        fragmentOrigin: CGPoint,
        context: CGContext
    ) {
        let cleanRuns = CTLineGetGlyphRuns(cleanCoreTextLine) as? [CTRun] ?? []
        let cleanClusters = Self.shapingClusters(
            in: cleanCoreTextLine,
            attributedString: cleanParagraph
        )
        let glyphSlicesByCluster = Self.glyphSlices(
            for: cleanClusters,
            from: cleanRuns
        )
        let rightToLeftClusterIndices = cleanClusters.indices.filter { index in
            cleanClusters[index].isRightToLeft
        }
        let lineOrigin = CGPoint(
            x: fragmentOrigin.x + lineFragment.typographicBounds.minX,
            y: fragmentOrigin.y + lineFragment.typographicBounds.minY
        )
        let baselineY = lineOrigin.y + lineFragment.glyphOrigin.y

        context.saveGState()
        context.translateBy(x: lineOrigin.x, y: baselineY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity

        // Nonhost soft lines need no translation. Draw their complete original Core Text
        // runs so contextual metrics and overhang remain byte-for-byte independent of the
        // presentation carrier on a different line.
        let lineHasSuffix = drawingParagraph.suffixWidthsByClusterLocation.keys.contains {
            lineRangeInParagraph.contains($0)
        }
        if !lineHasSuffix {
            for run in cleanRuns where CTRunGetStatus(run).contains(.rightToLeft) {
                CTRunDraw(
                    run,
                    context,
                    CFRange(location: 0, length: CTRunGetGlyphCount(run))
                )
            }
            context.restoreGState()
            return
        }

        let suffixHosts: [(sourceMinimumX: CGFloat, width: CGFloat)] =
            rightToLeftClusterIndices.compactMap { clusterIndex in
                let cluster = cleanClusters[clusterIndex]
                let width = drawingParagraph
                    .suffixWidthsByClusterLocation[cluster.range.location, default: 0]
                guard width > 0,
                      let sourceMinimumX = glyphSlicesByCluster[clusterIndex]
                        .map(\.sourceMinimumX)
                        .min() else {
                    return nil
                }
                return (sourceMinimumX, width)
        }
        for clusterIndex in rightToLeftClusterIndices {
            guard let sourceMinimumX = glyphSlicesByCluster[clusterIndex]
                .map(\.sourceMinimumX)
                .min() else {
                continue
            }
            let cumulativeSuffixWidth = suffixHosts.reduce(CGFloat.zero) { result, host in
                result + (host.sourceMinimumX <= sourceMinimumX + 0.001 ? host.width : 0)
            }
            Self.drawGlyphs(
                glyphSlicesByCluster[clusterIndex],
                targetMinimumX: sourceMinimumX + cumulativeSuffixWidth,
                in: context
            )
        }
        context.restoreGState()
    }

    /// A local Core Text shaping cluster used only during one fragment draw.
    private struct DrawingCluster {
        let range: NSRange
        let isRightToLeft: Bool
        let usesCaretAdvance: Bool
    }

    /// A contiguous glyph range from one clean Core Text run.
    ///
    /// A logical cluster normally maps to one slice, but the array representation also
    /// handles fonts that expose more than one visual slice for the same string index.
    private struct RunSlice {
        let run: CTRun
        let range: CFRange
        let sourceMinimumX: CGFloat
    }

    /// Reconstructs logical clusters from an already-shaped clean Core Text line.
    private static func shapingClusters(
        in line: CTLine,
        attributedString: NSAttributedString
    ) -> [DrawingCluster] {
        coreTextClusterMetrics(
            in: line,
            attributedString: attributedString
        ).map { cluster in
            DrawingCluster(
                range: cluster.range,
                isRightToLeft: cluster.isRightToLeft,
                usesCaretAdvance: cluster.usesCaretAdvance
            )
        }
    }

    /// Extracts all clean glyph slices with one linear walk over each Core Text run.
    ///
    /// The old drawing path reread every glyph array once per RTL cluster. Mapping UTF-16
    /// locations to cluster indices up front lets one run scan build the complete drawing
    /// plan. The returned outer array is aligned with `clusters`, so the draw loop needs no
    /// range lookup or glyph allocation.
    private static func glyphSlices(
        for clusters: [DrawingCluster],
        from runs: [CTRun]
    ) -> [[RunSlice]] {
        var clusterIndexByStringLocation = [Int: Int]()
        for (clusterIndex, cluster) in clusters.enumerated()
        where cluster.isRightToLeft {
            for location in cluster.range.location..<cluster.range.upperBound {
                clusterIndexByStringLocation[location] = clusterIndex
            }
        }

        var result = [[RunSlice]](repeating: [], count: clusters.count)
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else {
                continue
            }
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances = [CGSize](repeating: .zero, count: glyphCount)
            var indices = [CFIndex](repeating: 0, count: glyphCount)
            CTRunGetPositions(
                run,
                CFRange(location: 0, length: glyphCount),
                &positions
            )
            CTRunGetAdvances(
                run,
                CFRange(location: 0, length: glyphCount),
                &advances
            )
            CTRunGetStringIndices(
                run,
                CFRange(location: 0, length: glyphCount),
                &indices
            )

            var activeClusterIndex: Int?
            var sliceStart = 0
            for glyphIndex in 0...glyphCount {
                let nextClusterIndex: Int? = if glyphIndex < glyphCount {
                    clusterIndexByStringLocation[indices[glyphIndex]]
                } else {
                    nil
                }
                guard nextClusterIndex != activeClusterIndex else {
                    continue
                }

                if let activeClusterIndex, sliceStart < glyphIndex {
                    var sourceMinimumX = CGFloat.greatestFiniteMagnitude
                    for index in sliceStart..<glyphIndex {
                        sourceMinimumX = min(
                            sourceMinimumX,
                            positions[index].x,
                            positions[index].x + advances[index].width
                        )
                    }
                    result[activeClusterIndex].append(
                        RunSlice(
                            run: run,
                            range: CFRange(
                                location: sliceStart,
                                length: glyphIndex - sliceStart
                            ),
                            sourceMinimumX: sourceMinimumX
                        )
                    )
                }
                activeClusterIndex = nextClusterIndex
                sliceStart = glyphIndex
            }
        }
        return result
    }

    /// Finds a cluster's visual carrier bounds in the presentation Core Text line.
    ///
    /// A bidirectional boundary has primary and secondary offsets. The pair whose distance
    /// most closely matches the cluster's actual glyph advance identifies the correct
    /// visual box; blindly using the primary pair misplaces the first RTL cluster next to
    /// an LTR run in strings such as `AسلامB`.
    fileprivate static func visualBounds(
        of range: NSRange,
        in attributedString: NSAttributedString
    ) -> CGRect? {
        let line = CTLineCreateWithAttributedString(attributedString)
        let metric = coreTextClusterMetrics(
            in: line,
            attributedString: attributedString
        ).first { metric in
            metric.range == range
        }
        let expectedAdvance = coreTextAdvances(
            of: [range],
            in: line,
            caretAdvanceIndices: metric?.usesCaretAdvance == true ? [0] : []
        )[0]
        return visualBounds(
            of: range,
            expectedAdvance: expectedAdvance,
            in: line,
            caretOffsets: coreTextCaretOffsets(in: line),
            usesCaretAdvance: metric?.usesCaretAdvance == true
        )
    }

    /// Finds visual bounds using a caller-owned line and precomputed advance.
    ///
    /// The custom-fragment draw path calls this overload for every RTL cluster so the
    /// complete line is shaped exactly once. The attributed-string overload above remains
    /// for the one-off suffix-overlay lookup performed after viewport layout.
    private static func visualBounds(
        of range: NSRange,
        expectedAdvance: CGFloat,
        in line: CTLine,
        caretOffsets: [CoreTextCaretEdge: CGFloat],
        usesCaretAdvance: Bool
    ) -> CGRect? {
        if usesCaretAdvance,
           let caretSpan = coreTextCaretSpan(of: range, offsets: caretOffsets) {
            return CGRect(
                x: caretSpan.minimum,
                y: 0,
                width: caretSpan.width,
                height: 0
            )
        }

        // Some fonts omit caret edges for a zero-advance control cluster. Fall back to
        // Core Text's primary/secondary boundary API only for that exceptional case.
        var startSecondary: CGFloat = 0
        var endSecondary: CGFloat = 0
        let startPrimary = CTLineGetOffsetForStringIndex(
            line,
            range.location,
            &startSecondary
        )
        let endPrimary = CTLineGetOffsetForStringIndex(
            line,
            range.upperBound,
            &endSecondary
        )
        let startCandidates = [startPrimary, startSecondary]
        let endCandidates = [endPrimary, endSecondary]
        var bestPair: (start: CGFloat, end: CGFloat)?
        var bestError = CGFloat.greatestFiniteMagnitude
        for start in startCandidates {
            for end in endCandidates {
                let error = abs(abs(start - end) - expectedAdvance)
                if error < bestError {
                    bestError = error
                    bestPair = (start, end)
                }
            }
        }
        guard let bestPair else {
            return nil
        }
        return CGRect(
            x: min(bestPair.start, bestPair.end),
            y: 0,
            width: expectedAdvance,
            height: 0
        )
    }

    /// Draws precomputed clean glyph slices without applying the carrier's matrix.
    ///
    /// `CTRunDraw` receives the original clean run and therefore preserves contextual glyph
    /// selection, foreground color, color-font rendering, stroke, and shadow. Restricting it
    /// to the contiguous glyph ranges owned by this cluster prevents adjacent transparent
    /// carriers from being painted twice. Translating the context moves those original
    /// positions into the measured presentation box without scaling their shapes.
    private static func drawGlyphs(
        _ slices: [RunSlice],
        targetMinimumX: CGFloat,
        in context: CGContext
    ) {
        guard let clusterMinimumX = slices.map(\.sourceMinimumX).min() else {
            return
        }

        let translation = targetMinimumX - clusterMinimumX
        for slice in slices {
            context.saveGState()
            context.translateBy(x: translation, y: 0)
            CTRunDraw(slice.run, context, slice.range)
            context.restoreGState()
        }
    }
}
