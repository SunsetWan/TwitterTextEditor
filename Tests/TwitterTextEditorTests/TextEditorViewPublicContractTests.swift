//
//  TextEditorViewPublicContractTests.swift
//  TwitterTextEditor
//
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing
import TwitterTextEditor
import UIKit

private final class PublicChangeObserver: TextEditorViewChangeObserver {
    var changes: [(isTextChanged: Bool, isSelectedRangeChanged: Bool)] = []

    func textEditorView(_ textEditorView: TextEditorView,
                        didChangeWithChangeResult changeResult: TextEditorViewChangeResult)
    {
        changes.append((changeResult.isTextChanged, changeResult.isSelectedRangeChanged))
    }
}

private final class DeferredTextAttributesDelegate: TextEditorViewTextAttributesDelegate {
    var inputs: [NSAttributedString] = []
    var completions: [(NSAttributedString?) -> Void] = []

    func textEditorView(_ textEditorView: TextEditorView,
                        updateAttributedString attributedString: NSAttributedString,
                        completion: @escaping (NSAttributedString?) -> Void)
    {
        inputs.append(attributedString)
        completions.append(completion)
    }
}

private final class PublicTestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var value: Value {
        withValue { $0 }
    }
}

@MainActor
@Suite
struct TextEditorViewPublicContractTests {
    @Test("Replacing emoji uses UTF16 offsets and moves selection")
    func replacingEmojiMovesSelection() throws {
        let textEditorView = TextEditorView(frame: .zero)
        textEditorView.text = "A🐈B"
        textEditorView.selectedRange = NSRange(location: 4, length: 0)

        try textEditorView.updateByReplacing(
            range: NSRange(location: 1, length: 2),
            with: "猫"
        )

        #expect(textEditorView.text == "A猫B")
        #expect(textEditorView.selectedRange == NSRange(location: 3, length: 0))
    }

    @Test("Invalid replacement range throws without changing editing content")
    func invalidReplacementRangePreservesContent() {
        let textEditorView = TextEditorView(frame: .zero)
        textEditorView.text = "A🐈B"
        textEditorView.selectedRange = NSRange(location: 4, length: 0)

        #expect(throws: (any Error).self) {
            try textEditorView.updateByReplacing(
                range: NSRange(location: 5, length: 0),
                with: "ignored"
            )
        }
        #expect(textEditorView.text == "A🐈B")
        #expect(textEditorView.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test("Programmatic editing changes do not notify change observer")
    func programmaticChangesSkipObserver() async throws {
        let observer = PublicChangeObserver()
        let textEditorView = TextEditorView(frame: .zero)
        textEditorView.changeObserver = observer

        textEditorView.text = "A🐈B"
        textEditorView.selectedRange = NSRange(location: 4, length: 0)
        try textEditorView.updateByReplacing(
            range: NSRange(location: 1, length: 2),
            with: "猫"
        )

        try #require(await drainMainRunLoop())
        #expect(observer.changes.isEmpty)
        #expect(textEditorView.text == "A猫B")
        #expect(textEditorView.selectedRange == NSRange(location: 3, length: 0))
    }

    @Test("Latest asynchronous text attributes result wins")
    func latestAsyncAttributesWins() async throws {
        let delegate = DeferredTextAttributesDelegate()
        let textEditorView = TextEditorView(frame: .zero)
        textEditorView.text = "M"
        textEditorView.textAttributesDelegate = delegate

        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { delegate.inputs.count == 1 }, "First attributes request timed out")

        textEditorView.setNeedsUpdateTextAttributes()
        try #require(await waitUntil { delegate.inputs.count == 2 }, "Second attributes request timed out")
        #expect(delegate.inputs.count == 2)
        #expect(delegate.inputs.map(\.string) == ["M", "M"])

        let latestOutput = NSMutableAttributedString(attributedString: delegate.inputs[1])
        latestOutput.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 72),
            range: NSRange(location: 0, length: latestOutput.length)
        )
        delegate.completions[1](latestOutput)

        let obsoleteOutput = NSMutableAttributedString(attributedString: delegate.inputs[0])
        obsoleteOutput.addAttribute(
            .font,
            value: UIFont.systemFont(ofSize: 8),
            range: NSRange(location: 0, length: obsoleteOutput.length)
        )
        delegate.completions[0](obsoleteOutput)

        let fittingSize = textEditorView.sizeThatFits(
            CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        )
        #expect(fittingSize.height > 72)
    }

    @Test("Size that fits includes public text content insets")
    func sizeThatFitsIncludesInsets() {
        let textEditorView = TextEditorView(frame: .zero)
        textEditorView.font = UIFont.systemFont(ofSize: 20)
        textEditorView.text = "M"
        textEditorView.textContentPadding = 0
        textEditorView.textContentInsets = .zero
        let proposal = CGSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        let sizeWithoutInsets = textEditorView.sizeThatFits(proposal)

        textEditorView.textContentInsets = UIEdgeInsets(top: 11, left: 17, bottom: 13, right: 19)
        let sizeWithInsets = textEditorView.sizeThatFits(proposal)

        #expect(abs(sizeWithInsets.height - sizeWithoutInsets.height - 24) <= 0.5)
    }
}

@MainActor
private func drainMainRunLoop() async -> Bool {
    let reachedSentinel = PublicTestState(false)
    RunLoop.main.perform {
        reachedSentinel.withValue { $0 = true }
    }
    return await waitUntil { reachedSentinel.value }
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
