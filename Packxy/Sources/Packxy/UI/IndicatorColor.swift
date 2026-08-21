// The app's one severity palette.
//
// `ConnectionState.Indicator` is the vocabulary Packxy uses for "how
// worried should you be" — the menu-bar status dot, and the Ping tile's
// latency grade. Both need the same three colours, so the mapping lives
// here rather than being restated per view: two copies would drift, and
// a green that means different things in two places means nothing.

import SwiftUI

extension ConnectionState.Indicator {
    var color: Color {
        switch self {
        case .ok:   return .green
        case .warn: return .yellow
        case .bad:  return .red
        }
    }
}
