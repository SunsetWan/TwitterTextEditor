//
//  TextEditorViewTextKit2Tests.swift
//  TwitterTextEditor
//
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing
@testable import TwitterTextEditor
import UIKit

private final class TextAttributesDelegate: TextEditorViewTextAttributesDelegate {
    var update: (NSMutableAttributedString) -> Void
    private(set) var updateCount = 0

    init(update: @escaping (NSMutableAttributedString) -> Void = { attributedString in
             attributedString.addAttribute(.foregroundColor,
                                           value: UIColor.systemBlue,
                                           range: NSRange(location: 0, length: attributedString.length))
         })
    {
        self.update = update
    }

    func textEditorView(_ textEditorView: TextEditorView,
                        updateAttributedString attributedString: NSAttributedString,
                        completion: @escaping (NSAttributedString?) -> Void)
    {
        let updatedAttributedString = NSMutableAttributedString(attributedString: attributedString)
        update(updatedAttributedString)
        completion(updatedAttributedString)
        updateCount += 1
    }
}

@MainActor
@Suite(.serialized)
struct TextEditorViewTextKit2Tests {
    @Test("Initializes with TextKit 2 layout manager")
    func initializesWithTextKit2() {
        let textEditorView = TextEditorView(frame: .zero)

        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Updating text attributes keeps TextKit 2 layout manager")
    func updatesKeepTextKit2() async throws {
        let textAttributesDelegate = TextAttributesDelegate()
        let textEditorView = TextEditorView(frame: .zero)
        textEditorView.text = "Meow"
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Suffixed image preserves text selection and TextKit 2 layout manager")
    func suffixedImagePreservesSelection() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 12, height: 12)))
        }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(size: CGSize(width: 12, height: 12),
                                                                attachment: .image(image))
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 3, length: 1))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        textEditorView.text = "Meow"
        textEditorView.selectedRange = NSRange(location: 4, length: 0)
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        #expect(textEditorView.text == "Meow")
        #expect(textEditorView.selectedRange == NSRange(location: 4, length: 0))
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Suffixed image is rendered and removed with its attribute")
    func suffixedImageLifecycle() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 14)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 16, height: 14)))
        }
        let attachmentDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: CGSize(width: 16, height: 14),
                attachment: .image(image)
            )
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 0, length: 1))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        textEditorView.text = "M"
        textEditorView.textAttributesDelegate = attachmentDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { attachmentDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let renderedImageView = textEditorView.textContentView.subviews
            .compactMap { $0 as? UIImageView }
            .first { $0.image === image }
        #expect(renderedImageView?.frame.size == CGSize(width: 16, height: 14))
        let endPosition = try #require(textEditorView.textView.position(
            from: textEditorView.textView.beginningOfDocument,
            offset: 1
        ))
        let endCaret = textEditorView.textView.caretRect(for: endPosition)
        let imageView = try #require(renderedImageView)
        #expect(abs(imageView.frame.minX - endCaret.minX) <= 1)

        let removalDelegate = TextAttributesDelegate { attributedString in
            attributedString.removeAttribute(
                .suffixedAttachment,
                range: NSRange(location: 0, length: attributedString.length)
            )
        }
        textEditorView.textAttributesDelegate = removalDelegate
        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { removalDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        #expect(renderedImageView?.superview == nil)
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Tall suffixed image preserves host line metrics")
    func tallSuffixPreservesLineMetrics() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 40, height: 80)))
        }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(size: CGSize(width: 40, height: 80),
                                                                attachment: .image(image))
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 0, length: 1))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        textEditorView.text = "M"
        let sizeWithoutAttachment = textEditorView.sizeThatFits(
            CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        )
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        let sizeWithAttachment = textEditorView.sizeThatFits(
            CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        )
        textEditorView.layoutIfNeeded()
        let renderedImageView = textEditorView.textContentView.subviews
            .compactMap { $0 as? UIImageView }
            .first { $0.image === image }

        #expect(abs(sizeWithAttachment.height - sizeWithoutAttachment.height) <= 0.5)
        #expect(renderedImageView?.frame.size == CGSize(width: 40, height: 80))
    }

    @Test("Tall zero width suffix preserves wrapped line geometry")
    func zeroWidthSuffixPreservesWrap() async throws {
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 140, height: 240))
        textEditorView.font = UIFont.systemFont(ofSize: 20)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = Array(repeating: "word", count: 12).joined(separator: " ")
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineLines = textLayoutManager
            .laidOutLines()
        try #require(baselineLines.count > 2)
        let attachmentLocation = baselineLines[1].characterRange.location
        let attachmentEndPosition = try #require(textEditorView.textView.position(
            from: textEditorView.textView.beginningOfDocument,
            offset: attachmentLocation + 1
        ))
        let baselineAttachmentCaret = textEditorView.textView.caretRect(for: attachmentEndPosition)

        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 64)).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: CGSize(width: 0, height: 64),
                attachment: .image(image)
            )
            attributedString.addAttribute(
                .suffixedAttachment,
                value: attachment,
                range: NSRange(location: attachmentLocation, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedLines = textLayoutManager.laidOutLines()

        #expect(updatedLines.count == baselineLines.count)
        let updatedAttachmentCaret = textEditorView.textView.caretRect(for: attachmentEndPosition)
        #expect(abs(updatedAttachmentCaret.minY - baselineAttachmentCaret.minY) <= 1)
        for (baseline, updated) in zip(baselineLines, updatedLines) {
            #expect(abs(updated.frame.minY - baseline.frame.minY) <= 1)
            #expect(abs(updated.frame.height - baseline.frame.height) <= 1)
        }
    }

    @Test("Same suffixed image attribute across adjacent characters creates each suffix")
    func adjacentSuffixAttributesCreateEachSuffix() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 70, height: 18)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 70, height: 18)))
        }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(size: CGSize(width: 70, height: 18),
                                                                attachment: .image(image))
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 0, length: 2))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 120, height: 120))
        textEditorView.text = "MM"
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let imageViews = textEditorView.textContentView.subviews
            .compactMap { $0 as? UIImageView }
            .filter { $0.image === image }
        #expect(imageViews.count == 2)
        #expect(textEditorView.text == "MM")
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Nonterminal left to right suffix occupies reserved width without covering text")
    func leftToRightSuffixReservesWidth() async throws {
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "MM"
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        let suffixSize = CGSize(width: 20, height: 40)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: suffixSize,
                attachment: .image(image)
            )
            attributedString.addAttribute(
                .suffixedAttachment,
                value: attachment,
                range: NSRange(location: 0, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - suffixSize.width) <= 1)
        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let suffixFrameInEditor = renderedImageView.convert(
            renderedImageView.bounds,
            to: textEditorView
        )
        #expect(try #require(darkPixelCount(in: suffixFrameInEditor, of: textEditorView)) == 0)
        let endPosition = try #require(textEditorView.textView.position(
            from: textEditorView.textView.beginningOfDocument,
            offset: 1
        ))
        let endCaret = textEditorView.textView.caretRect(for: endPosition)
        #expect(abs(renderedImageView.frame.midX - endCaret.midX) <= 1)
        #expect(textEditorView.text == "MM")
        #expect(textEditorView.selectedRange == NSRange(location: 2, length: 0))
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Terminal left to right suffix occupies reserved trailing width")
    func terminalLeftToRightSuffixReservesWidth() async throws {
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "M"
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        let suffixSize = CGSize(width: 20, height: 40)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 0, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - suffixSize.width) <= 1)
        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let suffixFrame = renderedImageView.convert(renderedImageView.bounds, to: textEditorView)
        #expect(try #require(darkPixelCount(in: suffixFrame, of: textEditorView)) == 0)
    }

    @Test("Suffix in second paragraph uses document range and second line geometry")
    func secondParagraphUsesDocumentGeometry() async throws {
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 140))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "M\nMM"
        textEditorView.layoutIfNeeded()

        let suffixSize = CGSize(width: 20, height: 40)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                // `M\n` occupies the first two UTF-16 positions. This suffix therefore
                // exercises the conversion from the second paragraph's local line range
                // to the backing store's document range.
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        let endPosition = try #require(textEditorView.textView.position(
            from: textEditorView.textView.beginningOfDocument,
            offset: 3
        ))
        let endCaret = textEditorView.textView.caretRect(for: endPosition)
        #expect(abs(renderedImageView.frame.midX - endCaret.midX) <= 1)
        // Caret and line-fragment origins use slightly different pixel rounding at
        // 3x scale; a two-point tolerance still distinguishes this second line from
        // the first paragraph by more than an entire line height.
        #expect(abs(renderedImageView.frame.minY - endCaret.minY) <= 2)
        renderedImageView.isHidden = true
        let suffixFrame = renderedImageView.convert(renderedImageView.bounds, to: textEditorView)
        #expect(try #require(darkPixelCount(in: suffixFrame, of: textEditorView)) == 0)
        #expect(textEditorView.text == "M\nMM")
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Suffixed image on part of emoji preserves UTF16 text and selection")
    func emojiSuffixPreservesUTF16Selection() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 18)).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 40, height: 18)))
        }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(size: CGSize(width: 40, height: 18),
                                                                attachment: .image(image))
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 1, length: 1))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "🐈"
        textEditorView.selectedRange = NSRange(location: 2, length: 0)
        textEditorView.layoutIfNeeded()
        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - 40) <= 1)
        let renderedImageView = textEditorView.textContentView.subviews
            .compactMap { $0 as? UIImageView }
            .first { $0.image === image }
        #expect(renderedImageView?.frame.size == CGSize(width: 40, height: 18))
        #expect(textEditorView.text == "🐈")
        #expect(textEditorView.selectedRange == NSRange(location: 2, length: 0))
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Suffixed view on emoji is laid out without changing UTF16 selection")
    func emojiViewSuffixPreservesSelection() async throws {
        let suffixView = UIView()
        var laidOutFrames: [CGRect] = []
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: CGSize(width: 12, height: 12),
                attachment: .view(view: suffixView) { _, frame in
                    laidOutFrames.append(frame)
                }
            )
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 0, length: 2))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        textEditorView.text = "🐈"
        textEditorView.selectedRange = NSRange(location: 2, length: 0)
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        #expect(!laidOutFrames.isEmpty)
        #expect(textEditorView.text == "🐈")
        #expect(textEditorView.selectedRange == NSRange(location: 2, length: 0))
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Suffix tracking preserves a complete combining cluster")
    func suffixTrackingPreservesCombiningCluster() async throws {
        let text = "e\u{301}M"
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 100)
        )
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text
        textEditorView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        let suffixSize = CGSize(width: 20, height: 18)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                // Deliberately address only the combining mark. Presentation must expand
                // this metadata to the complete shaping cluster before adding tracking.
                range: NSRange(location: 1, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - suffixSize.width) <= 1)
        #expect(textEditorView.text == text)
        #expect(
            textEditorView.selectedRange
                == NSRange(location: (text as NSString).length, length: 0)
        )
    }

    @Test("Tall zero width suffix preserves right to left caret geometry")
    func zeroWidthSuffixPreservesRightToLeftCaret() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 80)).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: CGSize(width: 0, height: 80),
                attachment: .image(image)
            )
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 1, length: 1))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 80))
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.text = "سلام"
        textEditorView.selectedRange = NSRange(location: 4, length: 0)
        textEditorView.layoutIfNeeded()
        let caretPositionsBefore = try (0...4).map { offset in
            try #require(textEditorView.textView.position(
                from: textEditorView.textView.beginningOfDocument,
                offset: offset
            ))
        }.map { textEditorView.textView.caretRect(for: $0).minX }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let caretPositionsAfter = try (0...4).map { offset in
            try #require(textEditorView.textView.position(
                from: textEditorView.textView.beginningOfDocument,
                offset: offset
            ))
        }.map { textEditorView.textView.caretRect(for: $0).minX }
        for (caretBefore, caretAfter) in zip(caretPositionsBefore, caretPositionsAfter) {
            #expect(abs(caretAfter - caretBefore) <= 1)
        }
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Nonzero suffix width is reserved inside right to left shaping")
    func rightToLeftSuffixReservesShapingWidth() async throws {
        let text = "سلام"
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text
        textEditorView.selectedRange = NSRange(
            location: (text as NSString).length,
            length: 0
        )
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        let baselineGlyphPixelCount = try #require(
            darkPixelCount(in: textEditorView.bounds, of: textEditorView)
        )
        let suffixSize = CGSize(width: 20, height: 40)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: suffixSize,
                attachment: .image(image)
            )
            attributedString.addAttribute(
                .suffixedAttachment,
                value: attachment,
                // The lam-alef shaping cluster spans more than this one UTF-16 unit.
                // Presentation may reserve space for the complete cluster, but it must
                // keep the original Arabic glyphs and public string intact.
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - 20) <= 1)
        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let suffixFrameInEditor = renderedImageView.convert(
            renderedImageView.bounds,
            to: textEditorView
        )
        #expect(try #require(darkPixelCount(in: suffixFrameInEditor, of: textEditorView)) == 0)
        let updatedGlyphPixelCount = try #require(
            darkPixelCount(in: textEditorView.bounds, of: textEditorView)
        )
        // Presentation spacing must preserve the host's shaped glyphs. Compare ink
        // coverage with a small rasterization tolerance; a missing, substituted, or
        // disconnected Arabic glyph changes far more than this three-percent allowance.
        let glyphPixelTolerance = max(6, baselineGlyphPixelCount / 30)
        #expect(abs(updatedGlyphPixelCount - baselineGlyphPixelCount) <= glyphPixelTolerance)
        let updatedLine = try #require(textLayoutManager.laidOutLines().first)
        #expect(suffixFrameInEditor.minX >= updatedLine.frame.minX - 1)
        #expect(suffixFrameInEditor.maxX <= updatedLine.frame.maxX + 1)
        #expect(textEditorView.text == text)
        #expect(textEditorView.textView.text == text)
        #expect(
            textEditorView.selectedRange
                == NSRange(location: (text as NSString).length, length: 0)
        )
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Distinct suffixes inside one Arabic shaping cluster reserve independent gaps")
    func arabicClusterReservesIndependentGaps() async throws {
        let text = "سلام"
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 360, height: 100))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text
        textEditorView.selectedRange = NSRange(location: 2, length: 0)
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        let baselineGlyphPixelCount = try #require(
            darkPixelCount(in: textEditorView.bounds, of: textEditorView)
        )
        let suffixSize = CGSize(width: 20, height: 40)
        let firstImage = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let secondImage = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(firstImage)
                ),
                range: NSRange(location: 1, length: 1)
            )
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(secondImage)
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - 2 * suffixSize.width) <= 1)
        let firstImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === firstImage }
        )
        let secondImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === secondImage }
        )
        firstImageView.isHidden = true
        secondImageView.isHidden = true
        let firstFrame = firstImageView.convert(firstImageView.bounds, to: textEditorView)
        let secondFrame = secondImageView.convert(secondImageView.bounds, to: textEditorView)
        #expect(!firstFrame.intersects(secondFrame))
        #expect(try #require(darkPixelCount(in: firstFrame, of: textEditorView)) == 0)
        #expect(try #require(darkPixelCount(in: secondFrame, of: textEditorView)) == 0)
        let updatedGlyphPixelCount = try #require(
            darkPixelCount(in: textEditorView.bounds, of: textEditorView)
        )
        let glyphPixelTolerance = max(6, baselineGlyphPixelCount / 30)
        #expect(abs(updatedGlyphPixelCount - baselineGlyphPixelCount) <= glyphPixelTolerance)
        #expect(textEditorView.text == text)
        #expect(textEditorView.textView.text == text)
        #expect(textEditorView.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test("RTL presentation spacing stays out of public text selection and copy")
    func rightToLeftPresentationSpacingStaysPrivate() async throws {
        let text = "سلام"
        let textLength = (text as NSString).length
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 20, height: 20),
                    attachment: .image(image)
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 100)
        )
        textEditorView.text = text
        textEditorView.selectedRange = NSRange(location: textLength, length: 0)
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        // Presentation-only layout attributes must never leak through a public
        // UITextInput surface or change the backing UTF-16 coordinate space.
        #expect(textEditorView.text == text)
        #expect(textEditorView.textView.text == text)
        #expect(textEditorView.textView.attributedText.string == text)
        #expect(textEditorView.selectedRange == NSRange(location: textLength, length: 0))

        let documentStart = textEditorView.textView.beginningOfDocument
        let documentEnd = try #require(textEditorView.textView.position(
            from: documentStart,
            offset: textLength
        ))
        let documentRange = try #require(textEditorView.textView.textRange(
            from: documentStart,
            to: documentEnd
        ))
        #expect(textEditorView.textView.text(in: documentRange) == text)
        #expect(textEditorView.textView.position(
            from: documentStart,
            offset: textLength + 1
        ) == nil)

        textEditorView.selectedRange = NSRange(location: 0, length: textLength)
        let selectedStart = try #require(textEditorView.textView.position(
            from: documentStart,
            offset: textEditorView.selectedRange.location
        ))
        let selectedEnd = try #require(textEditorView.textView.position(
            from: selectedStart,
            offset: textEditorView.selectedRange.length
        ))
        let selectedTextRange = try #require(textEditorView.textView.textRange(
            from: selectedStart,
            to: selectedEnd
        ))
        // UIKit's copy command reads the selected UITextInput range. Assert that source
        // directly instead of mutating the process-wide pasteboard, which is both global
        // state and asynchronous on recent simulator runtimes.
        let copiedText = try #require(textEditorView.textView.text(in: selectedTextRange))
        #expect(copiedText == text)
        #expect(!copiedText.contains("\u{FFFC}"))
        #expect(textEditorView.selectedRange == NSRange(location: 0, length: textLength))
    }

    @Test("Right to left view suffix receives its reserved frame")
    func rightToLeftViewSuffixReceivesReservedFrame() async throws {
        let text = "سلام"
        let suffixSize = CGSize(width: 24, height: 18)
        let suffixView = UIView()
        var laidOutFrames: [CGRect] = []
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 100)
        )
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text
        textEditorView.selectedRange = NSRange(location: 2, length: 0)
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        textEditorView.textContentView.addSubview(suffixView)
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .view(view: suffixView) { view, frame in
                        view.frame = frame
                        laidOutFrames.append(frame)
                    }
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let suffixFrame = try #require(laidOutFrames.last)
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width

        #expect(suffixFrame.size == suffixSize)
        #expect(suffixView.frame == suffixFrame)
        #expect(abs(updatedWidth - baselineWidth - suffixSize.width) <= 1)
        #expect(try #require(darkPixelCount(in: suffixFrame, of: textEditorView)) == 0)
        #expect(textEditorView.text == text)
        #expect(textEditorView.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test("Terminal right to left suffix occupies the visual trailing gap")
    func terminalRightToLeftSuffixUsesTrailingGap() async throws {
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "سلام"
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        let suffixSize = CGSize(width: 20, height: 40)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 3, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - suffixSize.width) <= 1)
        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let suffixFrame = renderedImageView.convert(renderedImageView.bounds, to: textEditorView)
        let textFrame = try #require(textLayoutManager.laidOutLines().first).frame
        #expect(try #require(darkPixelCount(in: suffixFrame, of: textEditorView)) == 0)
        #expect(suffixFrame.minX >= textFrame.minX - 1)
        #expect(suffixFrame.maxX <= textFrame.maxX + 1)
    }

    @Test("Wide suffix that soft wraps stays beside its host line")
    func wideSuffixStaysWithHostLine() async throws {
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 130, height: 180))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "MMM"
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineLines = textLayoutManager.laidOutLines()
        try #require(baselineLines.count == 1)
        let suffixSize = CGSize(width: 50, height: 40)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 1, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedLines = textLayoutManager.laidOutLines()
        try #require(updatedLines.count == 2)
        let hostLine = try #require(updatedLines.first { line in
            NSLocationInRange(1, line.characterRange)
        })
        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let suffixFrame = renderedImageView.convert(renderedImageView.bounds, to: textEditorView)
        #expect(abs(suffixFrame.midY - hostLine.frame.minY) <= suffixSize.height / 2 + 1)
        #expect(try #require(darkPixelCount(in: suffixFrame, of: textEditorView)) == 0)
    }

    @Test("Right to left suffix before a newline reserves terminal line width")
    func rightToLeftSuffixBeforeNewlineReservesWidth() async throws {
        let referenceView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 140))
        referenceView.backgroundColor = .white
        referenceView.font = UIFont.systemFont(ofSize: 40)
        referenceView.textColor = .black
        referenceView.textContentInsets = .zero
        referenceView.textContentPadding = 0
        referenceView.text = "مم\n"
        referenceView.layoutIfNeeded()
        let referenceLayoutManager = try #require(referenceView.textView.textLayoutManager)
        let baselineWidth = try #require(referenceLayoutManager.laidOutLines().first).frame.width

        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 140))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "مم\n"
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let suffixSize = CGSize(width: 20, height: 40)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 1, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - suffixSize.width) <= 1)
        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let suffixFrame = renderedImageView.convert(renderedImageView.bounds, to: textEditorView)
        let overlapPixelCount = try #require(darkPixelCount(in: suffixFrame, of: textEditorView))
        let baselineOverhangPixelCount = try #require(
            darkPixelCount(in: suffixFrame, of: referenceView)
        )
        // Arabic glyphs can naturally overhang the visual-left edge. Compare with the
        // same unsuffixed line so the oracle remains stable across font revisions.
        #expect(overlapPixelCount <= baselineOverhangPixelCount)
    }

    @Test("Right to left suffix that causes wrapping reserves width on its host line")
    func wrappingRightToLeftSuffixReservesHostLine() async throws {
        // This narrow reference wraps the same Arabic pair without any suffix. It gives
        // us the contextual glyph width of each soft-wrapped line independently of the
        // suffix under test.
        let referenceView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 35, height: 180))
        referenceView.font = UIFont.systemFont(ofSize: 40)
        referenceView.textContentInsets = .zero
        referenceView.textContentPadding = 0
        referenceView.text = "مم"
        referenceView.layoutIfNeeded()
        let referenceLayoutManager = try #require(referenceView.textView.textLayoutManager)
        let referenceLines = referenceLayoutManager.laidOutLines()
        try #require(referenceLines.count == 2)

        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 55, height: 180))
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "مم"
        textEditorView.selectedRange = NSRange(location: 2, length: 0)
        textEditorView.layoutIfNeeded()
        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        try #require(textLayoutManager.laidOutLines().count == 1)

        let suffixSize = CGSize(width: 20, height: 40)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 0, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedLines = textLayoutManager.laidOutLines()
        try #require(updatedLines.count == 2)

        // The suffix belongs after the first logical character. When it forces the pair
        // apart, its width must remain on that first (host) line instead of widening the
        // following line merely because RTL visual order reverses the shaping pair.
        #expect(abs(updatedLines[0].frame.width - referenceLines[0].frame.width
                    - suffixSize.width) <= 1)
        #expect(abs(updatedLines[1].frame.width - referenceLines[1].frame.width) <= 1)

        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let suffixFrame = renderedImageView.convert(renderedImageView.bounds, to: textEditorView)
        let initiallyWrappedLineFrames = updatedLines.map(\.frame)
        let initiallyWrappedSuffixFrame = suffixFrame
        #expect(abs(suffixFrame.minY - updatedLines[0].frame.minY) <= 1)
        #expect(abs(suffixFrame.minX) <= 1)
        let overlapPixelCount = try #require(darkPixelCount(in: suffixFrame, of: textEditorView))
        let baselineOverhangPixelCount = try #require(
            darkPixelCount(in: suffixFrame, of: referenceView)
        )
        // The legacy control glyph places this suffix at the visual-left edge. Arabic
        // glyphs naturally overhang that edge, so zero dark pixels is not the correct
        // oracle. The overlay must not cover more text than the same line has without a
        // suffix.
        #expect(overlapPixelCount <= baselineOverhangPixelCount)

        // Expanding the container rejoins the shaping pair. Presentation must therefore
        // remove the narrow layout's stale host-line correction.
        textEditorView.frame.size.width = 120
        textEditorView.setNeedsLayout()
        textEditorView.layoutIfNeeded()
        let expandedLines = textLayoutManager.laidOutLines()
        try #require(expandedLines.count == 1)

        let expandedReferenceView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 120, height: 180)
        )
        expandedReferenceView.font = UIFont.systemFont(ofSize: 40)
        expandedReferenceView.textContentInsets = .zero
        expandedReferenceView.textContentPadding = 0
        expandedReferenceView.text = "مم"
        expandedReferenceView.layoutIfNeeded()
        let expandedReferenceLayoutManager = try #require(
            expandedReferenceView.textView.textLayoutManager
        )
        let expandedReferenceLine = try #require(
            expandedReferenceLayoutManager.laidOutLines().first
        )
        #expect(abs(expandedLines[0].frame.width - expandedReferenceLine.frame.width
                    - suffixSize.width) <= 1)
        let expandedSuffixFrame = renderedImageView.convert(
            renderedImageView.bounds,
            to: textEditorView
        )

        // Compare the resized result with an editor that started at the expanded width.
        // Equality here proves the cached host-carrier correction was removed; merely
        // checking total line width cannot distinguish the two presentation locations.
        let initiallyExpandedView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 120, height: 180)
        )
        initiallyExpandedView.backgroundColor = .white
        initiallyExpandedView.font = UIFont.systemFont(ofSize: 40)
        initiallyExpandedView.textColor = .black
        initiallyExpandedView.textContentInsets = .zero
        initiallyExpandedView.textContentPadding = 0
        initiallyExpandedView.text = "مم"
        let initiallyExpandedImage = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let initiallyExpandedDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(initiallyExpandedImage)
                ),
                range: NSRange(location: 0, length: 1)
            )
        }
        initiallyExpandedView.textAttributesDelegate = initiallyExpandedDelegate
        initiallyExpandedView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { initiallyExpandedDelegate.updateCount == 1 })
        initiallyExpandedView.layoutIfNeeded()
        let initiallyExpandedLine = try #require(
            initiallyExpandedView.textView.textLayoutManager?.laidOutLines().first
        )
        let initiallyExpandedImageView = try #require(
            initiallyExpandedView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === initiallyExpandedImage }
        )
        initiallyExpandedImageView.isHidden = true
        let initiallyExpandedSuffixFrame = initiallyExpandedImageView.convert(
            initiallyExpandedImageView.bounds,
            to: initiallyExpandedView
        )
        #expect(abs(expandedLines[0].frame.minX - initiallyExpandedLine.frame.minX) <= 1)
        #expect(abs(expandedLines[0].frame.width - initiallyExpandedLine.frame.width) <= 1)
        #expect(abs(expandedSuffixFrame.minX - initiallyExpandedSuffixFrame.minX) <= 1)
        #expect(abs(expandedSuffixFrame.minY - initiallyExpandedSuffixFrame.minY) <= 1)
        let expandedOverlapPixelCount = darkPixelCount(
            in: expandedSuffixFrame,
            of: textEditorView
        )
        let initiallyExpandedOverlapPixelCount = darkPixelCount(
            in: initiallyExpandedSuffixFrame,
            of: initiallyExpandedView
        )
        #expect(expandedOverlapPixelCount == initiallyExpandedOverlapPixelCount)

        // Shrinking again exercises the reverse transition as well. The same editor must
        // reproduce its original wrapped line and suffix geometry instead of retaining
        // presentation state from the expanded container.
        textEditorView.frame.size.width = 55
        textEditorView.setNeedsLayout()
        textEditorView.layoutIfNeeded()
        let rewrappedLines = textLayoutManager.laidOutLines()
        try #require(rewrappedLines.count == initiallyWrappedLineFrames.count)
        for (rewrappedLine, initialFrame) in zip(
            rewrappedLines,
            initiallyWrappedLineFrames
        ) {
            #expect(abs(rewrappedLine.frame.minX - initialFrame.minX) <= 1)
            #expect(abs(rewrappedLine.frame.minY - initialFrame.minY) <= 1)
            #expect(abs(rewrappedLine.frame.width - initialFrame.width) <= 1)
            #expect(abs(rewrappedLine.frame.height - initialFrame.height) <= 1)
        }
        let rewrappedSuffixFrame = renderedImageView.convert(
            renderedImageView.bounds,
            to: textEditorView
        )
        #expect(abs(rewrappedSuffixFrame.minX - initiallyWrappedSuffixFrame.minX) <= 1)
        #expect(abs(rewrappedSuffixFrame.minY - initiallyWrappedSuffixFrame.minY) <= 1)
        #expect(textEditorView.text == "مم")
        #expect(textEditorView.selectedRange == NSRange(location: 2, length: 0))
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Scrolling materializes suffixes for the new TextKit 2 viewport")
    func scrollingMaterializesViewportSuffixes() async throws {
        let topImage = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { _ in }
        let bottomImage = UIGraphicsImageRenderer(size: CGSize(width: 14, height: 12)).image { _ in }
        let text = Array(repeating: "line", count: 400).joined(separator: "\n")
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 12, height: 12),
                    attachment: .image(topImage)
                ),
                range: NSRange(location: 0, length: 1)
            )
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 14, height: 12),
                    attachment: .image(bottomImage)
                ),
                range: NSRange(location: attributedString.length - 1, length: 1)
            )
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text
        textEditorView.textAttributesDelegate = textAttributesDelegate

        // A window gives UITextView a real viewport; an offscreen text view legitimately
        // reports no viewport range and uses the implementation's whole-document fallback.
        let viewController = UIViewController()
        viewController.view.addSubview(textEditorView)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let imageViews = { @MainActor in
            textEditorView.textContentView.subviews.compactMap { $0 as? UIImageView }
        }
        try #require(await waitUntil {
            imageViews().contains { $0.image === topImage }
                && !imageViews().contains { $0.image === bottomImage }
        })

        let bottomOffset = max(
            0,
            textEditorView.scrollView.contentSize.height
                - textEditorView.scrollView.bounds.height
        )
        textEditorView.scrollView.setContentOffset(
            CGPoint(x: 0, y: bottomOffset),
            animated: false
        )

        try #require(await waitUntil {
            imageViews().contains { $0.image === bottomImage }
                && !imageViews().contains { $0.image === topImage }
        })
        #expect(textEditorView.text == text)
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Suffixed view is laid out in text container without changing text")
    func suffixedViewPreservesText() async throws {
        let suffixView = UIView()
        var laidOutFrames: [CGRect] = []
        let attachmentSize = CGSize(width: 24, height: 18)
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: attachmentSize,
                attachment: .view(view: suffixView) { view, frame in
                    view.frame = frame
                    laidOutFrames.append(frame)
                }
            )
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 0, length: 1))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        suffixView.removeFromSuperview()
        textEditorView.textContentView.addSubview(suffixView)
        textEditorView.text = "M"
        textEditorView.selectedRange = NSRange(location: 1, length: 0)
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.setNeedsLayout()
        textEditorView.layoutIfNeeded()
        #expect(!laidOutFrames.isEmpty)
        #expect(laidOutFrames.last?.size == attachmentSize)
        #expect(textEditorView.text == "M")
        #expect(textEditorView.selectedRange == NSRange(location: 1, length: 0))
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Suffixed view closure receives text container coordinates without insets")
    func suffixedViewCoordinatesExcludeInsets() async throws {
        let suffixView = UIView()
        var laidOutFrames: [CGRect] = []
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: CGSize(width: 20, height: 18),
                attachment: .view(view: suffixView) { _, frame in
                    laidOutFrames.append(frame)
                }
            )
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 0, length: 1))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
        textEditorView.text = "M"
        textEditorView.textContentInsets = .zero
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let frameWithoutInsets = try #require(laidOutFrames.last)

        textEditorView.textContentInsets = UIEdgeInsets(top: 11, left: 13, bottom: 0, right: 0)
        textEditorView.layoutIfNeeded()
        let frameWithInsets = try #require(laidOutFrames.last)

        #expect(abs(frameWithInsets.minX - frameWithoutInsets.minX) <= 0.5)
        #expect(abs(frameWithInsets.minY - frameWithoutInsets.minY) <= 0.5)
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test("Removed suffixed view is not laid out again")
    func removedSuffixedViewIsNotLaidOutAgain() async throws {
        let suffixView = UIView()
        var layoutCount = 0
        let attachmentDelegate = TextAttributesDelegate { attributedString in
            let attachment = TextAttributes.SuffixedAttachment(
                size: CGSize(width: 24, height: 18),
                attachment: .view(view: suffixView) { _, _ in
                    layoutCount += 1
                }
            )
            attributedString.addAttribute(.suffixedAttachment,
                                          value: attachment,
                                          range: NSRange(location: 0, length: 1))
        }
        let textEditorView = TextEditorView(frame: CGRect(x: 0, y: 0, width: 240, height: 80))
        textEditorView.text = "M"
        textEditorView.textAttributesDelegate = attachmentDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { attachmentDelegate.updateCount == 1 })
        textEditorView.setNeedsLayout()
        textEditorView.layoutIfNeeded()
        #expect(layoutCount > 0)

        let layoutCountBeforeRemoval = layoutCount
        let removalDelegate = TextAttributesDelegate { attributedString in
            attributedString.removeAttribute(.suffixedAttachment,
                                             range: NSRange(location: 0, length: attributedString.length))
        }
        textEditorView.textAttributesDelegate = removalDelegate
        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { removalDelegate.updateCount == 1 })
        textEditorView.setNeedsLayout()
        textEditorView.layoutIfNeeded()
        #expect(layoutCount == layoutCountBeforeRemoval)
        #expect(textEditorView.textView.textLayoutManager != nil)
    }
}

@MainActor
private func darkPixelCount(in rect: CGRect, of view: UIView) -> Int? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: rect.size))
        context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        view.layer.render(in: context.cgContext)
    }
    guard let cgImage = image.cgImage else {
        return nil
    }

    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    var pixels = [UInt8](repeating: 255, count: width * height * bytesPerPixel)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * bytesPerPixel,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return nil
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    return stride(from: 0, to: pixels.count, by: bytesPerPixel).reduce(into: 0) { count, offset in
        let red = pixels[offset]
        let green = pixels[offset + 1]
        let blue = pixels[offset + 2]
        if red < 200, green < 200, blue < 200 {
            count += 1
        }
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private extension NSTextLayoutManager {
    struct LaidOutLine {
        let characterRange: NSRange
        let frame: CGRect
    }

    func laidOutLines() -> [LaidOutLine] {
        guard let textContentManager else {
            return []
        }

        ensureLayout(for: textContentManager.documentRange)
        var lines: [LaidOutLine] = []
        enumerateTextLayoutFragments(
            from: textContentManager.documentRange.location,
            options: [.ensuresLayout]
        ) { textLayoutFragment in
            for textLineFragment in textLayoutFragment.textLineFragments {
                lines.append(
                    LaidOutLine(
                        characterRange: textLineFragment.characterRange,
                        frame: textLineFragment.typographicBounds.offsetBy(
                            dx: textLayoutFragment.layoutFragmentFrame.minX,
                            dy: textLayoutFragment.layoutFragmentFrame.minY
                        )
                    )
                )
            }
            return true
        }
        return lines
    }
}
