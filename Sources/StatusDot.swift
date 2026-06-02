import SwiftUI

/// Small colored status dot reused across rows.
struct StatusDot: View {
    let status: ServiceStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 0.5))
    }

    private var color: Color {
        switch status.dotColor {
        case .gray: return .secondary
        case .yellow: return .yellow
        case .green: return .green
        case .red: return .red
        }
    }
}
