//
//  TextKit2SuffixPresentation.swift
//  TwitterTextEditor
//
//  SPDX-License-Identifier: Apache-2.0
//

import CoreText
import UIKit

/**
 Presents `TextAttributes.SuffixedAttachment` values without changing the editor's
 backing string.

 TextKit 2 has no glyph-insertion API. A native `NSTextAttachment` would add an
 attachment character to the text and would therefore change public UTF-16 ranges,
 selection, copy/paste, undo, and marked-text behavior. Instead, this object gives
 `NSTextContentStorage` an equal-length presentation paragraph:

 - the custom suffix attribute is removed before TextKit lays out the paragraph;
 - standard character tracking at the host's shaping-cluster boundary reserves the suffix width;
 - the image or view is overlaid after TextKit has produced caret geometry.

 The presentation string preserves the backing string's UTF-16 code units, so the
 editor keeps a single position space for UIKit, clients, and input methods. Suffix
 height intentionally does not alter line metrics; this matches the previous
 control-glyph implementation and avoids moving the host glyph or selection geometry.

 `NSTextContentStorage.delegate` is weak. `TextEditorView` therefore retains this
 object for the lifetime of its text view.
 */
final class TextKit2SuffixPresentation: NSObject, NSTextContentStorageDelegate {
    /// Identifies one rendered image without relying on an attributed run's extent.
    ///
    /// The same attachment value may be applied to adjacent graphemes. Combining the
    /// UTF-16 location and object identity gives every visual suffix its own image view.
    private struct ImageKey: Hashable {
        let location: Int
        let suffix: ObjectIdentifier
    }

    /// A Core Text shaping cluster and the inline direction of the run that owns it.
    private struct ShapingCluster {
        let range: NSRange
        let isRightToLeft: Bool
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

    private var imageViews: [ImageKey: UIImageView] = [:]
    /// Document locations whose RTL spacing must remain on the host shaping cluster.
    ///
    /// RTL normally reserves visual trailing space on the next logical cluster. Once a
    /// soft wrap separates that pair, the next carrier belongs to the following line;
    /// recording the host here lets a rebuilt presentation paragraph move the same width
    /// back to the line that owns the suffix. These are presentation decisions only and
    /// never alter the backing string or its public UTF-16 coordinate space.
    private var wrappedRightToLeftHostLocations = Set<Int>()
    /// Guards the one temporary host-carrier probe used to resolve RTL soft wrapping.
    ///
    /// Tracking on the normal next-logical carrier is trailing whitespace. On older
    /// TextKit 2 releases that whitespace is excluded from the reported line width, so a
    /// first pass cannot reveal whether moving the same space to the host would wrap. A
    /// host probe lets TextKit answer that question with its real container geometry;
    /// `updateWrappedRightToLeftCarriers` then either keeps the host or restores the normal
    /// carrier and regenerates the paragraph once more.
    private var rightToLeftCarrierProbeLocations = Set<Int>()
    /// Locations whose current container width has already resolved the probe.
    private var resolvedRightToLeftCarrierLocations = Set<Int>()
    private var lastResolvedContainerWidth: CGFloat?

    /// Discards layout decisions whose inputs were replaced in the backing store.
    ///
    /// Carrier locations are keyed by UTF-16 offsets, so a character edit or a new
    /// attributed snapshot can make an otherwise valid decision refer to different text.
    /// `TextEditorView` calls this before those mutations are processed. Viewport-only
    /// invalidation pulses intentionally do not call it, which prevents probe loops.
    func backingContentWillChange() {
        wrappedRightToLeftHostLocations.removeAll()
        rightToLeftCarrierProbeLocations.removeAll()
        resolvedRightToLeftCarrierLocations.removeAll()
    }

    /// Invalidates carrier decisions after a public text-container setting changes.
    func layoutGeometryWillChange() {
        backingContentWillChange()
        lastResolvedContainerWidth = nil
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
        for group in suffixGroups {
            guard group.width != 0 else {
                continue
            }

            // A grapheme boundary is not necessarily a shaping boundary. Arabic and
            // Indic text, for example, may map several characters to one glyph cluster;
            // assigning spacing to an interior character is then ignored or breaks shaping.
            // Core Text exposes the string-index clusters produced from the same
            // attributed paragraph. Reserve the width at that cluster's first logical
            // code unit, which keeps the cluster intact for TextKit 2.
            // Core Text applies `tracking` between grapheme-cluster boundaries and treats
            // it as trailing whitespace. That space is visually after this cluster for
            // LTR runs. For RTL runs the visually trailing boundary belongs to the next
            // logical cluster, so use that carrier when one exists. At paragraph end,
            // the current cluster remains the only available carrier.
            let nextLogicalCluster = shapingClusters.first { candidate in
                candidate.range.location == group.cluster.range.upperBound
                    && !Self.isParagraphTerminator(
                        at: candidate.range,
                        in: paragraph.string
                    )
            }
            let hostDocumentLocation = range.location + group.cluster.range.location
            let usesHostCarrier = wrappedRightToLeftHostLocations.contains(hostDocumentLocation)
                || rightToLeftCarrierProbeLocations.contains(hostDocumentLocation)
            let spacingCluster = group.cluster.isRightToLeft && !usesHostCarrier
                ? nextLogicalCluster ?? group.cluster
                : group.cluster
            let spacingLocation = spacingCluster.range.location
            let spacingRange = spacingCluster.range

            // Apple documents that nonzero tracking disables nonessential ligatures
            // unless a ligature attribute is present. UIKit's normal default is enabled
            // even though the attributed string commonly omits the key. Materialize that
            // default across the complete shaping cluster: applying either attribute to a
            // single UTF-16 code unit could split a surrogate pair, ZWJ sequence, or
            // ligature. Explicit client values such as zero remain untouched.
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

        let currentContainerWidth = textView.textContainer.size.width
        if currentContainerWidth != lastResolvedContainerWidth {
            resolvedRightToLeftCarrierLocations.removeAll()
            lastResolvedContainerWidth = currentContainerWidth
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
        var laidOutLines = Self.laidOutLines(in: textLayoutManager)
        let suffixGroups = Self.suffixGroups(in: backingStore, range: suffixRange)

        // Start unresolved nonterminal RTL groups on their host carrier. This is a
        // presentation-only probe; the pass below keeps it only when TextKit actually
        // wraps the following cluster, otherwise it returns the space to the normal
        // next-logical carrier before positioning overlays.
        let probeLocations = Set(suffixGroups.compactMap { group -> Int? in
            guard group.cluster.isRightToLeft,
                  group.width != 0,
                  !wrappedRightToLeftHostLocations.contains(group.cluster.range.location),
                  !resolvedRightToLeftCarrierLocations.contains(group.cluster.range.location),
                  Self.nextLogicalCluster(after: group.cluster, in: backingStore) != nil
            else {
                return nil
            }
            return group.cluster.range.location
        })
        if !probeLocations.isEmpty {
            rightToLeftCarrierProbeLocations.formUnion(probeLocations)
            invalidatePresentationParagraphs(
                containing: probeLocations,
                backingStore: backingStore,
                textLayoutManager: textLayoutManager
            )
            textLayoutManager.textViewportLayoutController.layoutViewport()
            laidOutLines = Self.laidOutLines(in: textLayoutManager)
        }

        // Paragraph presentation happens before TextKit knows where soft wraps land.
        // The normal presentation uses the next logical RTL carrier; the temporary pass
        // above moves the same space to the host so TextKit can answer whether it wraps.
        // Keep that host only across a real break, then regenerate the affected paragraph.
        // No backing characters or public attributes change during either pass.
        if updateWrappedRightToLeftCarriers(
            for: suffixGroups,
            in: laidOutLines,
            backingStore: backingStore,
            textLayoutManager: textLayoutManager
        ) {
            textLayoutManager.textViewportLayoutController.layoutViewport()
            laidOutLines = Self.laidOutLines(in: textLayoutManager)
        }
        rightToLeftCarrierProbeLocations.subtract(probeLocations)
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
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        var clusters: [ShapingCluster] = []

        for run in runs {
            let runRange = CTRunGetStringRange(run)
            let runEnd = runRange.location + runRange.length
            let isRightToLeft = CTRunGetStatus(run).contains(.rightToLeft)
            var boundaries = [runRange.location, runEnd]
            let glyphCount = CTRunGetGlyphCount(run)
            if glyphCount > 0 {
                var stringIndices = [CFIndex](repeating: 0, count: glyphCount)
                CTRunGetStringIndices(run, CFRange(location: 0, length: glyphCount), &stringIndices)
                boundaries.append(contentsOf: stringIndices)
            }

            let sortedBoundaries = Array(Set(boundaries)).sorted()
            for (start, end) in zip(sortedBoundaries, sortedBoundaries.dropFirst()) where end > start {
                clusters.append(
                    ShapingCluster(
                        range: NSRange(location: start, length: end - start),
                        isRightToLeft: isRightToLeft
                    )
                )
            }
        }

        return clusters
    }

    /// Groups public suffixes by the shaping cluster that TextKit lays out atomically.
    ///
    /// Several graphemes can collapse into one Arabic or Indic cluster. Reserving width
    /// once per suffix at the same kern location produces an ambiguous gap and overlapping
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
                    isRightToLeft: cluster.isRightToLeft
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

    /// Rebuilds presentation paragraphs whose RTL suffix carrier crossed a soft wrap.
    ///
    /// Changing the carrier decision alone cannot invalidate a presentation paragraph
    /// that TextKit has already generated, and predicting breaks with another typesetter
    /// cannot exactly reproduce NSTextContainer geometry. Instead, inspect TextKit's real
    /// first pass, update the presentation decision, then report a zero-length attribute
    /// edit for each affected paragraph. `NSTextContentStorage` observes that edit and
    /// requests a new equal-length paragraph; the backing storage itself retains the same
    /// UTF-16 code units and attributes.
    private func updateWrappedRightToLeftCarriers(
        for groups: [SuffixGroup],
        in laidOutLines: [LaidOutLine],
        backingStore: NSTextStorage,
        textLayoutManager: NSTextLayoutManager
    ) -> Bool {
        var desiredHostLocations = wrappedRightToLeftHostLocations
        var evaluatedLocations = Set<Int>()
        for group in groups where group.cluster.isRightToLeft && group.width != 0 {
            let hostLocation = group.cluster.range.location
            guard !resolvedRightToLeftCarrierLocations.contains(hostLocation) else {
                continue
            }
            guard Self.nextLogicalCluster(
                after: group.cluster,
                in: backingStore
            ) != nil, let hostLine = laidOutLines.first(where: { line in
                line.characterRange.contains(group.cluster.range.location)
            }) else {
                continue
            }

            evaluatedLocations.insert(hostLocation)
            let pairCrossesSoftWrap = group.cluster.range.upperBound
                == hostLine.characterRange.upperBound
            if pairCrossesSoftWrap {
                desiredHostLocations.insert(hostLocation)
            } else {
                desiredHostLocations.remove(hostLocation)
            }
            resolvedRightToLeftCarrierLocations.insert(hostLocation)
        }

        // A viewport range can include a suffix whose line fragment has not materialized
        // yet. Clear its transient probe without sending another invalidation pulse; the
        // unresolved location will be probed again after it actually enters the viewport.
        // Only evaluated locations receive the final regeneration, which prevents a
        // layout/edit loop at viewport boundaries.
        rightToLeftCarrierProbeLocations.removeAll()
        guard !evaluatedLocations.isEmpty else {
            return false
        }
        wrappedRightToLeftHostLocations = desiredHostLocations

        invalidatePresentationParagraphs(
            containing: evaluatedLocations,
            backingStore: backingStore,
            textLayoutManager: textLayoutManager
        )
        return true
    }

    /// Invalidates only the presentation paragraphs that contain the given locations.
    ///
    /// `NSTextContentStorageDelegate` output is cached separately from the backing
    /// `NSTextStorage`. Reporting an attribute edit is an observation pulse that asks the
    /// content storage to rebuild equal-length paragraphs; it does not mutate public text
    /// or attributes.
    private func invalidatePresentationParagraphs(
        containing locations: Set<Int>,
        backingStore: NSTextStorage,
        textLayoutManager: NSTextLayoutManager
    ) {
        guard !locations.isEmpty else {
            return
        }
        let string = backingStore.string as NSString
        let paragraphRanges = Set(locations.map { location in
            string.paragraphRange(for: NSRange(location: location, length: 0))
        })

        backingStore.beginEditing()
        for paragraphRange in paragraphRanges {
            // `edited` is an observation pulse, not a mutation: the delegate's decision
            // changed even though the attributed backing store did not. Text storage
            // observers receive the minimum paragraph range that must be regenerated.
            backingStore.edited(
                .editedAttributes,
                range: paragraphRange,
                changeInLength: 0
            )
        }
        backingStore.endEditing()

        // The edit observer normally invalidates layout itself. Keep this explicit call
        // as a deterministic fallback for UIKit releases that retain the old fragment.
        guard let textContentManager = textLayoutManager.textContentManager else {
            return
        }
        for paragraphRange in paragraphRanges {
            guard let textRange = Self.textRange(
                paragraphRange,
                in: textContentManager
            ) else {
                continue
            }
            textLayoutManager.invalidateLayout(for: textRange)
        }
    }

    /// Finds the cluster immediately following `cluster` inside its paragraph.
    private static func nextLogicalCluster(
        after cluster: ShapingCluster,
        in attributedString: NSAttributedString
    ) -> ShapingCluster? {
        let paragraphRange = (attributedString.string as NSString).paragraphRange(
            for: NSRange(location: cluster.range.location, length: 0)
        )
        let paragraph = NSMutableAttributedString(
            attributedString: attributedString.attributedSubstring(from: paragraphRange)
        )
        paragraph.removeAttribute(
            .suffixedAttachment,
            range: NSRange(location: 0, length: paragraph.length)
        )
        let nextCluster = shapingClusters(in: paragraph).first { candidate in
            candidate.range.location == cluster.range.upperBound - paragraphRange.location
                && !isParagraphTerminator(at: candidate.range, in: paragraph.string)
        }
        guard let nextCluster else {
            return nil
        }
        return ShapingCluster(
            range: NSRange(
                location: paragraphRange.location + nextCluster.range.location,
                length: nextCluster.range.length
            ),
            isRightToLeft: nextCluster.isRightToLeft
        )
    }

    /// Returns whether a shaping cluster contains only a paragraph terminator.
    ///
    /// Core Text can expose the newline as a zero-glyph logical cluster. Tracking it is
    /// treated as trailing line whitespace and therefore reserves no inline box for a
    /// suffix immediately before the newline; such a host is terminal for our purposes.
    private static func isParagraphTerminator(at range: NSRange, in string: String) -> Bool {
        let terminators = CharacterSet.newlines
        let substring = (string as NSString).substring(with: range)
        return !substring.isEmpty && substring.unicodeScalars.allSatisfy { scalar in
            terminators.contains(scalar)
        }
    }

    /// Converts a backing-store UTF-16 range to a TextKit 2 document range.
    private static func textRange(
        _ range: NSRange,
        in textContentManager: NSTextContentManager
    ) -> NSTextRange? {
        let documentStart = textContentManager.documentRange.location
        guard let start = textContentManager.location(
            documentStart,
            offsetBy: range.location
        ), let end = textContentManager.location(
            start,
            offsetBy: range.length
        ) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }

    /// Returns the actual tracking gap for a cluster in TextKit's visual line.
    ///
    /// `UITextInput.caretRect` is unsuitable after a suffix itself causes wrapping: the
    /// logical end position can move to the next line even though the host cluster stays
    /// on the previous one. `NSTextLineFragment.characterRange` identifies the true host
    /// line; its typographic edge supplies the gap at a line end, while the caret remains
    /// useful as the centre of an interior tracked pair.
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
        let x: CGFloat
        let isTerminalRightToLeftCluster = group.cluster.isRightToLeft
            && Self.nextLogicalCluster(
                after: group.cluster,
                in: textView.textStorage
            ) == nil
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
            // following line, so line geometry is the only stable source. LTR tracking is
            // included at the right edge of the typographic bounds. RTL needs a separate
            // branch because its spacing carrier and actual reserved gap depend on whether a
            // following logical cluster was separated by this soft wrap.
            if group.cluster.isRightToLeft {
                if wrappedRightToLeftHostLocations.contains(group.cluster.range.location) {
                    // Moving tracking to a wrapped RTL host expands its right-aligned
                    // typographic frame toward the visual left without moving minX by the
                    // full suffix width. Place the overlay immediately before that edge,
                    // clamped to the text container, which reproduces the legacy control
                    // glyph's visual-left placement (including normal glyph overhang).
                    x = max(0, lineFrame.minX - group.width)
                } else {
                    // A terminal RTL cluster has no following logical carrier. Kerning
                    // its own first code unit opens a gap around that character's upstream
                    // edge. `locationForCharacter` exposes that kerning boundary in line
                    // coordinates; centring the overlay there uses the width TextKit
                    // actually reserved instead of assuming typographicBounds starts at a
                    // glyph edge (Arabic glyphs routinely overhang that edge).
                    let boundary = laidOutLine.origin.x + line.locationForCharacter(
                        at: line.characterRange.location
                            + group.cluster.range.location
                            - laidOutLine.characterRange.location
                    ).x
                    x = boundary - group.width / 2
                }
            } else {
                x = lineFrame.maxX - group.width
            }
        } else if isTerminalRightToLeftCluster {
            // A hard paragraph terminator can extend the line fragment's character range
            // beyond the final visible cluster. Treat that cluster exactly like the
            // terminal branch above instead of centring its suffix on the newline caret.
            let boundary = laidOutLine.origin.x + line.locationForCharacter(
                at: line.characterRange.location
                    + group.cluster.range.location
                    - laidOutLine.characterRange.location
            ).x
            x = boundary - group.width / 2
        } else {
            // For an interior pair, locationForCharacter and caretRect expose the centre
            // of the tracked pair, not either edge of the inserted space. Centre the whole
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
