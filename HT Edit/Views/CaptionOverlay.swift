//
//  CaptionOverlay.swift
//  HT Edit
//

import SwiftUI

/// The phrase being spoken, drawn over the bottom of the video.
struct CaptionOverlay: View {
    let model: TranscriptionModel

    var body: some View {
        if let text = model.captionText {
            Text(text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .accessibilityIdentifier("captionOverlay")
        }
    }
}
