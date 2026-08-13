//
//  TextEditorViewTextKit2Tests.swift
//  TwitterTextEditor
//
//  SPDX-License-Identifier: Apache-2.0
//

import CoreText
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

private final class TextLayoutManagerDelegateSpy: NSObject, NSTextLayoutManagerDelegate {
    private(set) var linkCallCount = 0
    private(set) var lineBreakCallCount = 0
    private(set) var fragmentCallCount = 0

    var fragment: NSTextLayoutFragment?

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        renderingAttributesForLink link: Any,
        at location: any NSTextLocation,
        defaultAttributes renderingAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any]? {
        linkCallCount += 1
        return [.foregroundColor: UIColor.magenta]
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        shouldBreakLineBefore location: any NSTextLocation,
        hyphenating: Bool
    ) -> Bool {
        lineBreakCallCount += 1
        return true
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        fragmentCallCount += 1
        return fragment ?? NSTextLayoutFragment(textElement: textElement, range: nil)
    }
}

private final class ResizeChangeObserver: TextEditorViewChangeObserver {
    private(set) var callCount = 0

    func textEditorView(
        _ textEditorView: TextEditorView,
        didChangeWithChangeResult changeResult: TextEditorViewChangeResult
    ) {
        callCount += 1
    }
}

private final class TextStorageEditingNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var notificationCount = 0
    private var token: NSObjectProtocol?

    init(textStorage: NSTextStorage) {
        token = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: textStorage,
            queue: nil
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.lock.lock()
            self.notificationCount += 1
            self.lock.unlock()
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return notificationCount
    }
}

private struct ParagraphSuffixLayoutCase {
    let text: String
    let width: CGFloat
    let suffixes: [(range: NSRange, width: CGFloat)]
    let paragraphStyle: NSParagraphStyle?
    let expectedRanges: [NSRange]
}

@MainActor
@Suite(.serialized)
struct TextEditorViewTextKit2Tests {
    @Test("RTL presentation rebuild on resize preserves public editing state")
    func resizePresentationRebuildPreservesPublicEditingState() async throws {
        let view = TextEditorView(frame: CGRect(x: 0, y: 0, width: 55, height: 180))
        view.font = UIFont.systemFont(ofSize: 40)
        view.textContentInsets = .zero
        view.textContentPadding = 0
        view.text = "مم"
        view.selectedRange = NSRange(location: 1, length: 0)
        let observer = ResizeChangeObserver()
        view.changeObserver = observer
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 40)).image { _ in }
        let delegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 20, height: 40),
                    attachment: .image(image)
                ),
                range: NSRange(location: 0, length: 1)
            )
        }
        view.textAttributesDelegate = delegate
        view.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { delegate.updateCount == 1 })
        view.layoutIfNeeded()

        let selectedRange = view.selectedRange
        let updateCount = delegate.updateCount
        let canUndo = view.textView.undoManager?.canUndo
        let canRedo = view.textView.undoManager?.canRedo
        #expect(view.textView.hasMarkedText == false)

        view.frame.size.width = 120
        view.setNeedsLayout()
        view.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(view.text == "مم")
        #expect(view.selectedRange == selectedRange)
        #expect(view.textView.hasMarkedText == false)
        #expect(delegate.updateCount == updateCount)
        #expect(observer.callCount == 0)
        #expect(view.textView.undoManager?.canUndo == canUndo)
        #expect(view.textView.undoManager?.canRedo == canRedo)
        #expect(view.textView.textLayoutManager != nil)
    }

    @Test("RTL presentation rebuild preserves active marked text")
    func resizePresentationRebuildPreservesActiveMarkedText() async throws {
        let view = TextEditorView(frame: CGRect(x: 0, y: 0, width: 55, height: 180))
        view.font = UIFont.systemFont(ofSize: 40)
        view.textContentInsets = .zero
        view.textContentPadding = 0
        view.text = "مم"
        let delegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 20, height: 40),
                    attachment: .image(UIImage())
                ),
                range: NSRange(location: 0, length: 1)
            )
        }
        view.textAttributesDelegate = delegate
        view.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { delegate.updateCount == 1 })
        view.layoutIfNeeded()

        view.textView.selectedRange = NSRange(location: 2, length: 0)
        view.textView.setMarkedText("س", selectedRange: NSRange(location: 1, length: 0))
        try #require(view.textView.hasMarkedText)
        let markedRange = try #require(view.textView.markedTextRange)
        let documentStart = view.textView.beginningOfDocument
        let markedOffsets = (
            view.textView.offset(from: documentStart, to: markedRange.start),
            view.textView.offset(from: documentStart, to: markedRange.end)
        )
        let text = view.textView.text
        let selectedRange = view.textView.selectedRange

        view.frame.size.width = 120
        view.setNeedsLayout()
        view.layoutIfNeeded()

        let resizedMarkedRange = try #require(view.textView.markedTextRange)
        #expect(view.textView.hasMarkedText)
        #expect(view.textView.text == text)
        #expect(view.textView.selectedRange == selectedRange)
        #expect(
            view.textView.offset(from: documentStart, to: resizedMarkedRange.start)
                == markedOffsets.0
        )
        #expect(
            view.textView.offset(from: documentStart, to: resizedMarkedRange.end)
                == markedOffsets.1
        )
        #expect(view.textView.textLayoutManager != nil)
    }

    @Test("RTL size that fits does not edit live backing storage")
    func rightToLeftSizeThatFitsDoesNotEditLiveStorage() async throws {
        let view = TextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        view.font = UIFont.systemFont(ofSize: 40)
        view.textContentInsets = .zero
        view.textContentPadding = 0
        view.text = "مممم"
        view.selectedRange = NSRange(location: 2, length: 0)
        let delegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 20, height: 20),
                    attachment: .image(UIImage())
                ),
                range: NSRange(location: 0, length: 1)
            )
        }
        view.textAttributesDelegate = delegate
        view.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { delegate.updateCount == 1 })
        view.layoutIfNeeded()
        let storageNotifications = TextStorageEditingNotificationCounter(
            textStorage: view.textView.textStorage
        )
        let selectedRange = view.selectedRange

        _ = view.sizeThatFits(
            CGSize(width: 55, height: CGFloat.greatestFiniteMagnitude)
        )
        _ = view.sizeThatFits(
            CGSize(width: 120, height: CGFloat.greatestFiniteMagnitude)
        )

        #expect(storageNotifications.count == 0)
        #expect(view.text == "مممم")
        #expect(view.selectedRange == selectedRange)
        #expect(view.textView.textLayoutManager != nil)
    }

    @Test("TextKit 2 presentation forwards UIKit layout delegate behavior")
    func presentationForwardsLayoutDelegate() throws {
        let textView = UITextView(usingTextLayoutManager: true)
        let textLayoutManager = try #require(textView.textLayoutManager)
        let spy = TextLayoutManagerDelegateSpy()
        textLayoutManager.delegate = spy
        let presentation = TextKit2SuffixPresentation()

        presentation.install(on: textLayoutManager)

        let installedDelegate = try #require(textLayoutManager.delegate)
        let location = try #require(textLayoutManager.textContentManager?.documentRange.location)
        let linkAttributes = installedDelegate.textLayoutManager?(
            textLayoutManager,
            renderingAttributesForLink: "https://example.com",
            at: location,
            defaultAttributes: [:]
        )
        let shouldBreak = installedDelegate.textLayoutManager?(
            textLayoutManager,
            shouldBreakLineBefore: location,
            hyphenating: false
        )
        let paragraph = NSTextParagraph(attributedString: NSAttributedString(string: "M"))
        let expectedFragment = NSTextLayoutFragment(textElement: paragraph, range: nil)
        spy.fragment = expectedFragment
        let forwardedFragment = installedDelegate.textLayoutManager?(
            textLayoutManager,
            textLayoutFragmentFor: location,
            in: paragraph
        )

        #expect((linkAttributes?[.foregroundColor] as? UIColor) == .magenta)
        #expect(shouldBreak == true)
        #expect(forwardedFragment === expectedFragment)
        #expect(spy.linkCallCount == 1)
        #expect(spy.lineBreakCallCount == 1)
        #expect(spy.fragmentCallCount == 1)
    }

    @Test("TextKit 2 presentation keeps inherited UIKit link decoration in an RTL suffix run")
    func rightToLeftSuffixPreservesInheritedLinkDecorationColor() async throws {
        let dynamicLinkColor = UIColor { _ in .magenta }
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: dynamicLinkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        let baselineView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 100)
        )
        baselineView.backgroundColor = .white
        baselineView.font = UIFont.systemFont(ofSize: 40)
        baselineView.textContentInsets = .zero
        baselineView.textContentPadding = 0
        baselineView.textView.linkTextAttributes = linkAttributes
        baselineView.text = "سلام"
        let baselineDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .link,
                value: URL(string: "https://example.com")!,
                range: NSRange(location: 0, length: attributedString.length)
            )
        }
        baselineView.textAttributesDelegate = baselineDelegate
        baselineView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { baselineDelegate.updateCount == 1 })
        baselineView.layoutIfNeeded()
        let baselineMagenta = try #require(saturatedPixelCount(
            .magenta,
            in: baselineView.bounds,
            of: baselineView
        ))

        let suffixView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 100)
        )
        suffixView.backgroundColor = .white
        suffixView.font = UIFont.systemFont(ofSize: 40)
        suffixView.textContentInsets = .zero
        suffixView.textContentPadding = 0
        suffixView.textView.linkTextAttributes = linkAttributes
        suffixView.text = "سلام"
        suffixView.selectedRange = NSRange(location: 2, length: 0)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 18)).image { _ in }
        let suffixDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .link,
                value: URL(string: "https://example.com")!,
                range: NSRange(location: 0, length: attributedString.length)
            )
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 20, height: 18),
                    attachment: .image(image)
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        suffixView.textAttributesDelegate = suffixDelegate
        suffixView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { suffixDelegate.updateCount == 1 })
        suffixView.layoutIfNeeded()
        suffixView.textContentView.subviews
            .compactMap { $0 as? UIImageView }
            .forEach { $0.isHidden = true }
        let suffixedMagenta = try #require(saturatedPixelCount(
            .magenta,
            in: suffixView.bounds,
            of: suffixView
        ))

        #expect(baselineMagenta > 0)
        #expect(abs(suffixedMagenta - baselineMagenta) <= max(8, baselineMagenta / 10))
        #expect(suffixView.text == "سلام")
        #expect(suffixView.selectedRange == NSRange(location: 2, length: 0))
        #expect(suffixView.textView.textLayoutManager != nil)
    }

    @Test("A native text attachment coexists with an RTL suffix in the same paragraph")
    func nativeAttachmentCoexistsWithRightToLeftSuffix() async throws {
        let nativeImage = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 18, height: 18))
        }
        let suffixImage = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 18)).image { _ in }
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 100)
        )
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "\u{FFFC}سلام"
        textEditorView.selectedRange = NSRange(location: 5, length: 0)
        let attributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .attachment,
                value: NSTextAttachment(image: nativeImage),
                range: NSRange(location: 0, length: 1)
            )
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 20, height: 18),
                    attachment: .image(suffixImage)
                ),
                range: NSRange(location: 3, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = attributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { attributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let textContentManager = try #require(textLayoutManager.textContentManager)
        textLayoutManager.ensureLayout(for: textContentManager.documentRange)
        let attachmentLocation = try #require(textContentManager.location(
            textContentManager.documentRange.location,
            offsetBy: 0
        ))
        var attachmentFrame = CGRect.null
        textLayoutManager.enumerateTextLayoutFragments(
            from: textContentManager.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            let candidate = fragment.frameForTextAttachment(at: attachmentLocation)
            if !candidate.isEmpty {
                attachmentFrame = candidate
                return false
            }
            return true
        }
        let bluePixels = try #require(saturatedPixelCount(
            .blue,
            in: textEditorView.bounds,
            of: textEditorView
        ))

        #expect(!attachmentFrame.isEmpty)
        #expect(bluePixels > 0)
        #expect(textEditorView.text == "\u{FFFC}سلام")
        #expect(textEditorView.selectedRange == NSRange(location: 5, length: 0))
        #expect(textEditorView.textView.textLayoutManager != nil)
    }

    @Test(
        "RTL suffix update and layout remain bounded for long text",
        arguments: [512, 1_024]
    )
    func longRightToLeftPresentationIsBounded(length: Int) async throws {
        let text = String(repeating: "م", count: length)
        let view = TextEditorView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        view.font = UIFont.systemFont(ofSize: 20)
        view.textContentInsets = .zero
        view.textContentPadding = 0
        view.text = text
        let delegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: CGSize(width: 20, height: 18),
                    attachment: .image(UIImage())
                ),
                range: NSRange(location: length / 2, length: 1)
            )
        }
        view.textAttributesDelegate = delegate
        let clock = ContinuousClock()
        let start = clock.now

        view.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { delegate.updateCount == 1 })
        view.layoutIfNeeded()

        let elapsed = start.duration(to: clock.now)
        #expect(view.text == text)
        #expect(view.textView.textLayoutManager != nil)
        #expect(!(try #require(view.textView.textLayoutManager).laidOutLines()).isEmpty)
        #expect(elapsed < .milliseconds(1_500))
    }

    @Test("RTL presentation does not impose a hidden suffix width ceiling")
    func rightToLeftPresentationHasNoHiddenWidthCeiling() throws {
        let suffixWidth: CGFloat = 50_000
        let attributedString = NSMutableAttributedString(
            string: "م",
            attributes: [.font: UIFont.systemFont(ofSize: 20)]
        )
        let baselineLine = CTLineCreateWithAttributedString(attributedString)
        let baselineWidth = CGFloat(CTLineGetTypographicBounds(
            baselineLine,
            nil,
            nil,
            nil
        ))
        attributedString.addAttribute(
            .suffixedAttachment,
            value: TextAttributes.SuffixedAttachment(
                size: CGSize(width: suffixWidth, height: 18),
                attachment: .image(UIImage())
            ),
            range: NSRange(location: 0, length: 1)
        )
        let contentStorage = NSTextContentStorage()
        contentStorage.attributedString = attributedString
        let presentation = TextKit2SuffixPresentation()

        let paragraph = try #require(presentation.textContentStorage(
            contentStorage,
            textParagraphWith: NSRange(location: 0, length: attributedString.length)
        ))
        let presentationLine = CTLineCreateWithAttributedString(paragraph.attributedString)
        let presentationWidth = CGFloat(CTLineGetTypographicBounds(
            presentationLine,
            nil,
            nil,
            nil
        ))

        #expect(abs(presentationWidth - baselineWidth - suffixWidth) <= 1)
    }

    @Test("TextKit reserves an LTR suffix once for a multi-glyph composed cluster")
    func textKitLeftToRightFlagClusterReservesSuffixWidthOnce() async throws {
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 100)
        )
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "A🇺🇸B"
        textEditorView.textView.textStorage.addAttribute(
            .ligature,
            value: NSNumber(value: 0),
            range: NSRange(location: 0, length: textEditorView.textView.textStorage.length)
        )
        textEditorView.layoutIfNeeded()
        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        let suffixSize = CGSize(width: 20, height: 18)
        let delegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(UIImage())
                ),
                range: NSRange(location: 1, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = delegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { delegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedWidth = try #require(textLayoutManager.laidOutLines().first).frame.width
        #expect(abs(updatedWidth - baselineWidth - suffixSize.width) <= 1)
    }

    @Test("Text container line-break mode does not replace the default paragraph style")
    func textContainerLineBreakModeDoesNotOverrideDefaultParagraph() async throws {
        func laidOutRanges(for mode: NSLineBreakMode) async throws -> [NSRange] {
            let textEditorView = TextEditorView(
                frame: CGRect(x: 0, y: 0, width: 105, height: 220)
            )
            textEditorView.font = UIFont.systemFont(ofSize: 20)
            textEditorView.textContentInsets = .zero
            textEditorView.textContentPadding = 0
            textEditorView.textView.textContainer.lineBreakMode = mode
            textEditorView.text = "سلام hello world"
            let delegate = TextAttributesDelegate { attributedString in
                attributedString.addAttribute(
                    .suffixedAttachment,
                    value: TextAttributes.SuffixedAttachment(
                        size: CGSize(width: 8, height: 18),
                        attachment: .image(UIImage())
                    ),
                    range: NSRange(location: 0, length: 1)
                )
            }
            textEditorView.textAttributesDelegate = delegate
            textEditorView.setNeedsUpdateTextAttributes()
            try #require(await waitUntil { delegate.updateCount == 1 })
            textEditorView.layoutIfNeeded()
            let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
            return textLayoutManager.laidOutLines().map(\.characterRange)
        }

        let defaultRanges = try await laidOutRanges(for: .byWordWrapping)
        let containerByCharacterRanges = try await laidOutRanges(for: .byCharWrapping)

        #expect(containerByCharacterRanges == defaultRanges)
    }

    @Test("RTL suffix planning honors word, indent, by-character, and mixed bidi lines")
    func rightToLeftSuffixPlanningHonorsParagraphPolicy() async throws {
        let indented = NSMutableParagraphStyle()
        indented.firstLineHeadIndent = 18
        indented.headIndent = 8
        indented.tailIndent = -10
        let byCharacter = NSMutableParagraphStyle()
        byCharacter.lineBreakMode = .byCharWrapping
        let cases = [
            ParagraphSuffixLayoutCase(
                text: "سلام hello world",
                width: 105,
                suffixes: [(NSRange(location: 0, length: 1), 8)],
                paragraphStyle: nil,
                expectedRanges: [
                    NSRange(location: 0, length: 5),
                    NSRange(location: 5, length: 6),
                    NSRange(location: 11, length: 5)
                ]
            ),
            ParagraphSuffixLayoutCase(
                text: "سلام hello world",
                width: 105,
                suffixes: [
                    (NSRange(location: 0, length: 1), 8),
                    (NSRange(location: 14, length: 1), 24)
                ],
                paragraphStyle: nil,
                expectedRanges: [
                    NSRange(location: 0, length: 5),
                    NSRange(location: 5, length: 6),
                    NSRange(location: 11, length: 4),
                    NSRange(location: 15, length: 1)
                ]
            ),
            ParagraphSuffixLayoutCase(
                text: "سلام hello world again",
                width: 180,
                suffixes: [(NSRange(location: 0, length: 1), 16)],
                paragraphStyle: indented,
                expectedRanges: [
                    NSRange(location: 0, length: 5),
                    NSRange(location: 5, length: 6),
                    NSRange(location: 11, length: 6),
                    NSRange(location: 17, length: 5)
                ]
            ),
            ParagraphSuffixLayoutCase(
                text: "سلامhelloworld",
                width: 95,
                suffixes: [(NSRange(location: 0, length: 1), 12)],
                paragraphStyle: byCharacter,
                expectedRanges: [
                    NSRange(location: 0, length: 4),
                    NSRange(location: 4, length: 5),
                    NSRange(location: 9, length: 5)
                ]
            ),
            ParagraphSuffixLayoutCase(
                text: "Aسلام BسلامC",
                width: 105,
                suffixes: [(NSRange(location: 2, length: 1), 18)],
                paragraphStyle: nil,
                expectedRanges: [
                    NSRange(location: 0, length: 4),
                    NSRange(location: 4, length: 2),
                    NSRange(location: 6, length: 5),
                    NSRange(location: 11, length: 1)
                ]
            )
        ]

        for testCase in cases {
            let view = TextEditorView(
                frame: CGRect(x: 0, y: 0, width: testCase.width, height: 400)
            )
            view.font = UIFont.systemFont(ofSize: 40)
            view.textContentInsets = .zero
            view.textContentPadding = 0
            view.text = testCase.text
            let images = testCase.suffixes.map { suffix in
                UIGraphicsImageRenderer(
                    size: CGSize(width: suffix.width, height: 20)
                ).image { _ in }
            }
            let delegate = TextAttributesDelegate { attributedString in
                if let paragraphStyle = testCase.paragraphStyle {
                    attributedString.addAttribute(
                        .paragraphStyle,
                        value: paragraphStyle,
                        range: NSRange(location: 0, length: attributedString.length)
                    )
                }
                for (index, suffix) in testCase.suffixes.enumerated() {
                    attributedString.addAttribute(
                        .suffixedAttachment,
                        value: TextAttributes.SuffixedAttachment(
                            size: CGSize(width: suffix.width, height: 20),
                            attachment: .image(images[index])
                        ),
                        range: suffix.range
                    )
                }
            }
            view.textAttributesDelegate = delegate
            view.setNeedsUpdateTextAttributes()
            try #require(await waitUntil { delegate.updateCount == 1 })
            view.layoutIfNeeded()
            let textLayoutManager = try #require(view.textView.textLayoutManager)
            let ranges = textLayoutManager.laidOutLines().map(\.characterRange)

            #expect(ranges == testCase.expectedRanges)
            #expect(
                ranges.flatMap { Array($0.location..<$0.upperBound) }
                    == Array(0..<(testCase.text as NSString).length)
            )
            #expect(view.textView.textLayoutManager != nil)
        }
    }

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

    @Test("Right to left combining marks add exactly the suffix width")
    func rightToLeftCombiningMarksAddExactSuffixWidth() async throws {
        let text = "سَلَام"
        let suffixSize = CGSize(width: 20, height: 18)
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 100)
        )
        textEditorView.font = UIFont.systemFont(ofSize: 40)
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
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                // Target the first fatha. Its negative advance positions the mark over
                // the base glyph and must not be counted as additional inline width.
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

    @Test("Right to left soft wraps preserve contextual line glyphs")
    func rightToLeftSoftWrapPreservesContextualGlyphs() async throws {
        let text = "العربيةالعربية"
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 40, height: 360)
        )
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineLines = textLayoutManager.laidOutLines()
        try #require(baselineLines.count > 2)
        let baselineGlyphPixelCount = try #require(
            darkPixelCount(in: textEditorView.bounds, of: textEditorView)
        )

        let suffixSize = CGSize(width: 1, height: 1)
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
        try #require(updatedLines.count == baselineLines.count)
        #expect(updatedLines.map(\.characterRange) == baselineLines.map(\.characterRange))
        for index in baselineLines.indices.dropFirst() {
            #expect(abs(updatedLines[index].frame.width - baselineLines[index].frame.width) <= 1)
        }

        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let updatedGlyphPixelCount = try #require(
            darkPixelCount(in: textEditorView.bounds, of: textEditorView)
        )
        let glyphPixelTolerance = max(12, baselineGlyphPixelCount / 20)
        #expect(abs(updatedGlyphPixelCount - baselineGlyphPixelCount) <= glyphPixelTolerance)
    }

    @Test("Right to left suffix layout converges instead of alternating soft wraps")
    func rightToLeftSuffixLayoutConverges() async throws {
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 63, height: 360)
        )
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = "العربيةالعربية"
        let suffixSize = CGSize(width: 1, height: 1)
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

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let initialLines = textLayoutManager.laidOutLines()
        try #require(!initialLines.isEmpty)
        let initialSignature = initialLines.map { line in
            (line.characterRange, line.frame)
        }

        for _ in 0..<6 {
            textEditorView.setNeedsLayout()
            textEditorView.layoutIfNeeded()
            let signature = textLayoutManager.laidOutLines().map { line in
                (line.characterRange, line.frame)
            }
            #expect(signature.count == initialSignature.count)
            for (current, initial) in zip(signature, initialSignature) {
                #expect(current.0 == initial.0)
                #expect(abs(current.1.minX - initial.1.minX) <= 0.01)
                #expect(abs(current.1.minY - initial.1.minY) <= 0.01)
                #expect(abs(current.1.width - initial.1.width) <= 0.01)
                #expect(abs(current.1.height - initial.1.height) <= 0.01)
            }
        }
    }

    @Test("Mixed bidirectional suffix preserves layout input and shaped glyphs")
    func mixedBidirectionalSuffixPreservesEditingContract() async throws {
        let text = "AسلامB"
        let textLength = (text as NSString).length
        let selectedRange = NSRange(location: 2, length: 2)
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 400, height: 100)
        )
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textColor = .black
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text
        textEditorView.selectedRange = selectedRange
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineLine = try #require(textLayoutManager.laidOutLines().first)
        let baselineCaretOrigins = try caretOrigins(
            in: textEditorView.textView,
            utf16Length: textLength
        )
        let baselineGlyphPixelCount = try #require(
            darkPixelCount(in: textEditorView.bounds, of: textEditorView)
        )
        let suffixSize = CGSize(width: 20, height: 18)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let textAttributesDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                // Exercise a suffix inside the Arabic run rather than at either bidi
                // boundary. Presentation may reshape that run, but it must not replace
                // any of the six public UTF-16 code units.
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = textAttributesDelegate

        textEditorView.setNeedsUpdateTextAttributes()

        try #require(await waitUntil { textAttributesDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()
        let updatedLine = try #require(textLayoutManager.laidOutLines().first)
        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let updatedGlyphPixelCount = try #require(
            darkPixelCount(in: textEditorView.bounds, of: textEditorView)
        )
        let updatedCaretOrigins = try caretOrigins(
            in: textEditorView.textView,
            utf16Length: textLength
        )

        #expect(abs(updatedLine.frame.width - baselineLine.frame.width - suffixSize.width) <= 1)
        #expect(abs(updatedLine.frame.height - baselineLine.frame.height) <= 0.5)

        // Every adjacent public UTF-16 position must retain its own caret stop and the
        // same bidi direction. This catches presentation strings that replace Arabic
        // characters with attachments and collapse several logical offsets together.
        for index in 0..<textLength {
            let baselineDelta = baselineCaretOrigins[index + 1].x
                - baselineCaretOrigins[index].x
            let updatedDelta = updatedCaretOrigins[index + 1].x
                - updatedCaretOrigins[index].x
            #expect(abs(baselineDelta) > 0.5)
            #expect(abs(updatedDelta) > 0.5)
            #expect(baselineDelta * updatedDelta > 0)
        }

        // Hiding the transparent suffix leaves only client text. A missing or visibly
        // stretched Arabic run changes ink coverage by far more than this rasterization
        // tolerance, while normal subpixel positioning remains within it.
        let glyphPixelTolerance = max(8, baselineGlyphPixelCount / 20)
        #expect(abs(updatedGlyphPixelCount - baselineGlyphPixelCount) <= glyphPixelTolerance)
        #expect(textEditorView.text == text)
        #expect(textEditorView.textView.text == text)
        #expect(textEditorView.textView.attributedText.string == text)
        #expect(textEditorView.selectedRange == selectedRange)
        #expect(textEditorView.textView.textLayoutManager === textLayoutManager)
    }

    @Test("Right to left suffix preserves client foreground colors")
    func rightToLeftSuffixPreservesClientForegroundColors() async throws {
        let text = "سلام"
        let red = UIColor.red
        let blue = UIColor.blue
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 100)
        )
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text

        func applyClientColors(to attributedString: NSMutableAttributedString) {
            attributedString.addAttribute(
                .foregroundColor,
                value: red,
                range: NSRange(location: 0, length: 2)
            )
            attributedString.addAttribute(
                .foregroundColor,
                value: blue,
                range: NSRange(location: 2, length: 2)
            )
        }

        let colorDelegate = TextAttributesDelegate { attributedString in
            applyClientColors(to: attributedString)
        }
        textEditorView.textAttributesDelegate = colorDelegate
        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { colorDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        let baselineRedPixelCount = try #require(
            saturatedPixelCount(.red, in: textEditorView.bounds, of: textEditorView)
        )
        let baselineBluePixelCount = try #require(
            saturatedPixelCount(.blue, in: textEditorView.bounds, of: textEditorView)
        )
        try #require(baselineRedPixelCount > 10)
        try #require(baselineBluePixelCount > 10)

        let suffixSize = CGSize(width: 20, height: 18)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let suffixDelegate = TextAttributesDelegate { attributedString in
            applyClientColors(to: attributedString)
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = suffixDelegate
        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { suffixDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let updatedRedPixelCount = try #require(
            saturatedPixelCount(.red, in: textEditorView.bounds, of: textEditorView)
        )
        let updatedBluePixelCount = try #require(
            saturatedPixelCount(.blue, in: textEditorView.bounds, of: textEditorView)
        )

        // Position changes can alter antialiasing at a few edge pixels, but each client
        // color must retain essentially the same amount of visible glyph ink.
        let redTolerance = max(12, baselineRedPixelCount / 8)
        let blueTolerance = max(12, baselineBluePixelCount / 8)
        #expect(abs(updatedRedPixelCount - baselineRedPixelCount) <= redTolerance)
        #expect(abs(updatedBluePixelCount - baselineBluePixelCount) <= blueTolerance)
        #expect(
            (textEditorView.textView.attributedText.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? UIColor)?.isEqual(red) == true
        )
        #expect(
            (textEditorView.textView.attributedText.attribute(
                .foregroundColor,
                at: 2,
                effectiveRange: nil
            ) as? UIColor)?.isEqual(blue) == true
        )
        #expect(textEditorView.text == text)
    }

    @Test("Right to left suffix preserves client decorations and background")
    func rightToLeftSuffixPreservesClientDecorations() async throws {
        let text = "سلام"
        let textRange = NSRange(location: 0, length: (text as NSString).length)
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 100)
        )
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text

        func applyClientDecorations(to attributedString: NSMutableAttributedString) {
            attributedString.addAttributes(
                [
                    .foregroundColor: UIColor.black,
                    .backgroundColor: UIColor.yellow,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: UIColor.red,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: UIColor.blue
                ],
                range: textRange
            )
        }

        let decorationDelegate = TextAttributesDelegate { attributedString in
            applyClientDecorations(to: attributedString)
        }
        textEditorView.textAttributesDelegate = decorationDelegate
        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { decorationDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        let baselineUnderlinePixelCount = try #require(
            saturatedPixelCount(.red, in: textEditorView.bounds, of: textEditorView)
        )
        let baselineStrikethroughPixelCount = try #require(
            saturatedPixelCount(.blue, in: textEditorView.bounds, of: textEditorView)
        )
        let baselineBackgroundPixelCount = try #require(
            saturatedPixelCount(.yellow, in: textEditorView.bounds, of: textEditorView)
        )
        try #require(baselineUnderlinePixelCount > 10)
        try #require(baselineStrikethroughPixelCount > 10)
        try #require(baselineBackgroundPixelCount > 100)

        let suffixSize = CGSize(width: 20, height: 18)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let suffixDelegate = TextAttributesDelegate { attributedString in
            applyClientDecorations(to: attributedString)
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = suffixDelegate
        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { suffixDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let updatedUnderlinePixelCount = try #require(
            saturatedPixelCount(.red, in: textEditorView.bounds, of: textEditorView)
        )
        let updatedStrikethroughPixelCount = try #require(
            saturatedPixelCount(.blue, in: textEditorView.bounds, of: textEditorView)
        )
        let updatedBackgroundPixelCount = try #require(
            saturatedPixelCount(.yellow, in: textEditorView.bounds, of: textEditorView)
        )

        // This oracle deliberately checks durable presence instead of pixel equality.
        // TextKit may extend decoration or background ink into the reserved gap, while
        // dropping a client decoration makes its saturated pixel count approach zero.
        #expect(updatedUnderlinePixelCount >= baselineUnderlinePixelCount * 3 / 4)
        #expect(updatedStrikethroughPixelCount >= baselineStrikethroughPixelCount * 3 / 4)
        #expect(updatedBackgroundPixelCount >= baselineBackgroundPixelCount * 3 / 4)
        let publicAttributes = textEditorView.textView.attributedText.attributes(
            at: 1,
            effectiveRange: nil
        )
        #expect(
            (publicAttributes[.underlineStyle] as? NSNumber)?.intValue
                == NSUnderlineStyle.single.rawValue
        )
        #expect(
            (publicAttributes[.strikethroughStyle] as? NSNumber)?.intValue
                == NSUnderlineStyle.single.rawValue
        )
        #expect(
            (publicAttributes[.backgroundColor] as? UIColor)?.isEqual(UIColor.yellow) == true
        )
        #expect(textEditorView.text == text)
    }

    @Test("RTL suffix preserves decoration colors inherited from the foreground")
    func rightToLeftSuffixPreservesInheritedDecorationColors() async throws {
        let text = "سلام"
        let textRange = NSRange(location: 0, length: (text as NSString).length)

        func makeEditor() -> TextEditorView {
            let editor = TextEditorView(
                frame: CGRect(x: 0, y: 0, width: 320, height: 100)
            )
            editor.backgroundColor = .white
            editor.font = UIFont.systemFont(ofSize: 40)
            editor.textContentInsets = .zero
            editor.textContentPadding = 0
            editor.text = text
            return editor
        }

        func applyDecorations(to attributedString: NSMutableAttributedString) {
            attributedString.addAttributes(
                [
                    .foregroundColor: UIColor.magenta,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue
                ],
                range: textRange
            )
        }

        let baselineEditor = makeEditor()
        let baselineDelegate = TextAttributesDelegate(update: applyDecorations)
        baselineEditor.textAttributesDelegate = baselineDelegate
        baselineEditor.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { baselineDelegate.updateCount == 1 })
        baselineEditor.layoutIfNeeded()
        let baselineMagentaPixels = try #require(saturatedPixelCount(
            .magenta,
            in: baselineEditor.bounds,
            of: baselineEditor
        ))
        try #require(baselineMagentaPixels > 100)

        let suffixEditor = makeEditor()
        let suffixSize = CGSize(width: 20, height: 18)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let suffixDelegate = TextAttributesDelegate { attributedString in
            applyDecorations(to: attributedString)
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        suffixEditor.textAttributesDelegate = suffixDelegate
        suffixEditor.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { suffixDelegate.updateCount == 1 })
        suffixEditor.layoutIfNeeded()
        let renderedImageView = try #require(
            suffixEditor.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let suffixedMagentaPixels = try #require(saturatedPixelCount(
            .magenta,
            in: suffixEditor.bounds,
            of: suffixEditor
        ))

        // TextKit can split the continuous native decoration at a transformed host-run
        // boundary, but losing either inherited decoration removes substantially more ink.
        let tolerance = max(24, baselineMagentaPixels / 5)
        #expect(abs(suffixedMagentaPixels - baselineMagentaPixels) <= tolerance)
        #expect(suffixEditor.text == text)
        #expect(suffixEditor.textView.textLayoutManager != nil)
    }

    @Test("Right to left suffix coexists with client tracking")
    func rightToLeftSuffixCoexistsWithClientTracking() async throws {
        let text = "سلام"
        let textRange = NSRange(location: 0, length: (text as NSString).length)
        let clientTracking = NSNumber(value: 6.0)
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 100)
        )
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text
        textEditorView.selectedRange = NSRange(location: textRange.length, length: 0)

        let trackingDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .tracking,
                value: clientTracking,
                range: textRange
            )
        }
        textEditorView.textAttributesDelegate = trackingDelegate
        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { trackingDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        let textLayoutManager = try #require(textEditorView.textView.textLayoutManager)
        let baselineLine = try #require(textLayoutManager.laidOutLines().first)
        let suffixSize = CGSize(width: 20, height: 18)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let suffixDelegate = TextAttributesDelegate { attributedString in
            attributedString.addAttribute(
                .tracking,
                value: clientTracking,
                range: textRange
            )
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = suffixDelegate
        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { suffixDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        let updatedLine = try #require(textLayoutManager.laidOutLines().first)
        #expect(abs(updatedLine.frame.width - baselineLine.frame.width - suffixSize.width) <= 1)
        #expect(abs(updatedLine.frame.height - baselineLine.frame.height) <= 0.5)
        for location in 0..<textRange.length {
            #expect(
                (textEditorView.textView.attributedText.attribute(
                    .tracking,
                    at: location,
                    effectiveRange: nil
                ) as? NSNumber)?.doubleValue == clientTracking.doubleValue
            )
        }
        #expect(textEditorView.text == text)
        #expect(textEditorView.selectedRange == NSRange(location: textRange.length, length: 0))
        #expect(textEditorView.textView.textLayoutManager === textLayoutManager)
    }

    @Test("Right to left suffix preserves client stroke and shadow")
    func rightToLeftSuffixPreservesClientStrokeAndShadow() async throws {
        let text = "سلام"
        let textRange = NSRange(location: 0, length: (text as NSString).length)
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.magenta
        shadow.shadowOffset = CGSize(width: 4, height: 4)
        shadow.shadowBlurRadius = 0
        let textEditorView = TextEditorView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 100)
        )
        textEditorView.backgroundColor = .white
        textEditorView.font = UIFont.systemFont(ofSize: 40)
        textEditorView.textContentInsets = .zero
        textEditorView.textContentPadding = 0
        textEditorView.text = text

        func applyClientEffects(to attributedString: NSMutableAttributedString) {
            attributedString.addAttributes(
                [
                    .foregroundColor: UIColor.black,
                    .strokeColor: UIColor.blue,
                    .strokeWidth: NSNumber(value: -2),
                    .shadow: shadow
                ],
                range: textRange
            )
        }

        let effectsDelegate = TextAttributesDelegate { attributedString in
            applyClientEffects(to: attributedString)
        }
        textEditorView.textAttributesDelegate = effectsDelegate
        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { effectsDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        let baselineStrokePixelCount = try #require(
            saturatedPixelCount(.blue, in: textEditorView.bounds, of: textEditorView)
        )
        let baselineShadowPixelCount = try #require(
            saturatedPixelCount(.magenta, in: textEditorView.bounds, of: textEditorView)
        )
        try #require(baselineStrokePixelCount > 10)
        try #require(baselineShadowPixelCount > 10)

        let suffixSize = CGSize(width: 20, height: 18)
        let image = UIGraphicsImageRenderer(size: suffixSize).image { _ in }
        let suffixDelegate = TextAttributesDelegate { attributedString in
            applyClientEffects(to: attributedString)
            attributedString.addAttribute(
                .suffixedAttachment,
                value: TextAttributes.SuffixedAttachment(
                    size: suffixSize,
                    attachment: .image(image)
                ),
                range: NSRange(location: 2, length: 1)
            )
        }
        textEditorView.textAttributesDelegate = suffixDelegate
        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { suffixDelegate.updateCount == 1 })
        textEditorView.layoutIfNeeded()

        let renderedImageView = try #require(
            textEditorView.textContentView.subviews
                .compactMap { $0 as? UIImageView }
                .first { $0.image === image }
        )
        renderedImageView.isHidden = true
        let updatedStrokePixelCount = try #require(
            saturatedPixelCount(.blue, in: textEditorView.bounds, of: textEditorView)
        )
        let updatedShadowPixelCount = try #require(
            saturatedPixelCount(.magenta, in: textEditorView.bounds, of: textEditorView)
        )

        #expect(updatedStrokePixelCount >= baselineStrokePixelCount * 3 / 4)
        #expect(updatedShadowPixelCount >= baselineShadowPixelCount * 3 / 4)
        let publicAttributes = textEditorView.textView.attributedText.attributes(
            at: 1,
            effectiveRange: nil
        )
        #expect((publicAttributes[.strokeColor] as? UIColor)?.isEqual(UIColor.blue) == true)
        #expect((publicAttributes[.strokeWidth] as? NSNumber)?.doubleValue == -2)
        #expect((publicAttributes[.shadow] as? NSShadow) === shadow)
        #expect(textEditorView.text == text)
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
        let baselineInkBounds = try #require(darkPixelBounds(
            in: textEditorView.bounds,
            of: textEditorView
        ))
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
        let updatedInkBounds = try #require(darkPixelBounds(
            in: textEditorView.bounds,
            of: textEditorView
        ))
        #expect(try #require(darkPixelCount(in: suffixFrame, of: textEditorView)) == 0)
        #expect(abs(updatedInkBounds.width - baselineInkBounds.width) <= 1)
        #expect(abs(updatedInkBounds.height - baselineInkBounds.height) <= 1)
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

private enum SaturatedPixelTone {
    case red
    case blue
    case yellow
    case magenta

    func matches(red: Int, green: Int, blue: Int) -> Bool {
        switch self {
        case .red:
            return red > 140 && red - green > 40 && red - blue > 40
        case .blue:
            return blue > 140 && blue - red > 40 && blue - green > 40
        case .yellow:
            return red > 140 && green > 140 && min(red, green) - blue > 40
        case .magenta:
            return red > 140 && blue > 140 && min(red, blue) - green > 40
        }
    }
}

@MainActor
private func darkPixelCount(in rect: CGRect, of view: UIView) -> Int? {
    pixelCount(in: rect, of: view) { red, green, blue in
        red < 200 && green < 200 && blue < 200
    }
}

@MainActor
private func darkPixelBounds(in rect: CGRect, of view: UIView) -> CGRect? {
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

    var minimumX = width
    var minimumY = height
    var maximumX = -1
    var maximumY = -1
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * bytesPerPixel
            let isDark = pixels[offset] < 200
                && pixels[offset + 1] < 200
                && pixels[offset + 2] < 200
            guard isDark else {
                continue
            }
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }
    guard maximumX >= minimumX, maximumY >= minimumY else {
        return nil
    }
    return CGRect(
        x: minimumX,
        y: minimumY,
        width: maximumX - minimumX + 1,
        height: maximumY - minimumY + 1
    )
}

@MainActor
private func saturatedPixelCount(
    _ tone: SaturatedPixelTone,
    in rect: CGRect,
    of view: UIView
) -> Int? {
    pixelCount(in: rect, of: view) { red, green, blue in
        tone.matches(red: red, green: green, blue: blue)
    }
}

@MainActor
private func pixelCount(
    in rect: CGRect,
    of view: UIView,
    matching predicate: (Int, Int, Int) -> Bool
) -> Int? {
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
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        if predicate(red, green, blue) {
            count += 1
        }
    }
}

@MainActor
private func caretOrigins(in textView: UITextView, utf16Length: Int) throws -> [CGPoint] {
    try (0...utf16Length).map { offset in
        let position = try #require(textView.position(
            from: textView.beginningOfDocument,
            offset: offset
        ))
        return textView.caretRect(for: position).origin
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
