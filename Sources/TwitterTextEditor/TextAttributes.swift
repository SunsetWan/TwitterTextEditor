//
//  TextAttributes.swift
//  TwitterTextEditor
//
//  Copyright 2021 Twitter, Inc.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import UIKit

/**
 Namespace for additional text attributes supported by `TextEditorView`.
 */
public enum TextAttributes {
    /**
     A text attribute value that displays an image or view after an attributed grapheme.

     The suffix is presentation-only: it does not insert an attachment character into
     the editor's text and therefore does not change UTF-16 ranges or selection. Its
     width participates in line wrapping. Its height controls the rendered image or view
     frame but does not change the text line's metrics.
     */
    public final class SuffixedAttachment: NSObject {
        /**
         A text attributes key for this value.

         - SeeAlso:
           - `NSAttributedString.Key.suffixedAttachment`
         */
        public static let attributeName = NSAttributedString.Key(rawValue: "TTESuffixedAttachment")

        /**
         An attachment representation.
         */
        public enum Attachment {
            /**
             A still image attachment represented as `UIImage`.
             */
            case image(UIImage)
            /**
             An arbitrary view that represented as `UIView`.

             - Parameters:
               - view: A `UIView` that is added to the text editor view.
               - layoutInTextContainer: A block that lays out `view` in `frame`.
                 The frame uses `NSTextContainer` coordinates and therefore excludes
                 `TextEditorView.textContentInsets`. When `view` is a subview of
                 `TextEditorView.textContentView`, offset the frame once by the left and
                 top content insets to convert it to that view's coordinate space.
                 Text layout can invoke this block more than once, so it must be idempotent.

             - SeeAlso:
               - `TextEditorView.textContentView`
               - `TextEditorView.textContentInsets`
               - `TextEditorView.textContentPadding`
             */
            case view(view: UIView, layoutInTextContainer: (UIView, CGRect) -> Void)
        }

        /// The visual size and inline width of the suffix attachment.
        public let size: CGSize
        /**
         The attachment representation.
         */
        public let attachment: Attachment

        /**
         Initialize with an attachment representation.

         - Parameters:
           - size: Size of the attachment.
           - attachment: An attachment representation.
         */
        public init(size: CGSize, attachment: Attachment) {
            self.size = size
            self.attachment = attachment

            super.init()
        }

        /// :nodoc:
        public override var description: String {
            "<\(type(of: self)): " +
            "size = \(size), " +
            "attachment = \(attachment)}" +
            ">"
        }
    }
}

extension NSAttributedString.Key {
    /**
     A text attributes key for `TextAttributes.SuffixedAttachment`.
     */
    public static let suffixedAttachment = TextAttributes.SuffixedAttachment.attributeName
}
