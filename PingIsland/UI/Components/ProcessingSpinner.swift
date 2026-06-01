//
//  ProcessingSpinner.swift
//  PingIsland
//
//  Animated dots indicator for processing state
//

import SwiftUI

struct ThinkingDotsIndicator: View {
    let color: Color
    let dotSize: CGFloat
    let spacing: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(color: Color = .white, dotSize: CGFloat = 3.4, spacing: CGFloat = 2.6) {
        self.color = color
        self.dotSize = dotSize
        self.spacing = spacing
    }

    var body: some View {
        if reduceMotion {
            dots(at: nil)
        } else {
            TimelineView(.periodic(from: .now, by: 0.12)) { context in
                dots(at: context.date)
            }
        }
    }

    private func dots(at date: Date?) -> some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color.opacity(opacity(at: date, index: index)))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .frame(width: dotSize * 3 + spacing * 2, height: dotSize)
    }

    private func opacity(at date: Date?, index: Int) -> Double {
        guard let date, !reduceMotion else {
            return index == 1 ? 1.0 : 0.74
        }

        let wave = sin(date.timeIntervalSinceReferenceDate * 4.8 - Double(index) * 0.8)
        return 0.58 + ((wave + 1) / 2) * 0.42
    }
}

struct ProcessingSpinner: View {
    let color: Color

    init(color: Color = .white) {
        self.color = color
    }

    var body: some View {
        ThinkingDotsIndicator(color: color, dotSize: 3.2, spacing: 2.4)
    }
}

#Preview {
    ProcessingSpinner()
        .frame(width: 30, height: 30)
        .background(.black)
}
