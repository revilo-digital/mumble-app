import SwiftUI

/// The black pill: ✕ to cancel, the dots while listening or working, ✓ to finish.
struct WidgetView: View {
    let controller: DictationController

    var body: some View {
        // Nothing at all when hidden, so the animated dots don't keep redrawing off screen.
        if controller.phase != .idle { pill }
    }

    private var pill: some View {
        Group {
            if case let .notice(text) = controller.phase {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
            } else {
                HStack(spacing: 10) {
                    RoundButton(symbol: "xmark", foreground: .white, background: Color(white: 0.32), help: "Cancel") {
                        controller.cancel()
                    }
                    Group {
                        if controller.phase == .working {
                            WorkingDots()
                        } else {
                            LevelDots(level: controller.level)
                        }
                    }
                    .frame(width: 76, height: 24)
                    RoundButton(symbol: "checkmark", foreground: .black, background: .white, help: "Done") {
                        controller.finish()
                    }
                    .opacity(controller.phase == .working ? 0.4 : 1)
                }
                .padding(6)
            }
        }
        .background(Capsule().fill(.black))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .fixedSize()
    }
}

private struct RoundButton: View {
    let symbol: String
    let foreground: Color
    let background: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A row of dots that stretch into bars with the voice, tallest in the middle.
private struct LevelDots: View {
    let level: Float
    private let count = 9

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .frame(width: 4, height: height(index, time))
                }
            }
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }

    private func height(_ index: Int, _ time: TimeInterval) -> CGFloat {
        let middle = Double(count - 1) / 2
        let envelope = 1 - abs(Double(index) - middle) / (middle + 1)
        let wobble = 0.6 + 0.4 * sin(time * 9 + Double(index) * 1.7)
        return 4 + CGFloat(Double(level) * envelope * wobble) * 18
    }
}

/// Dots fading in turn while the text is being worked on.
private struct WorkingDots: View {
    private let count = 9

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(.white)
                        .frame(width: 4, height: 4)
                        .opacity(0.3 + 0.7 * max(0, sin(time * 6 - Double(index) * 0.6)))
                }
            }
        }
    }
}
