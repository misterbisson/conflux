import ConfluxCore
import SwiftUI

/// The Memory pressure tile: the whole device's memory pressure, which
/// counts the GPU's memory and every other app's, and what resource policy
/// is doing about it (`MemoryStatus`), with how it's gone.
public struct MemoryPressureTile: View {
    let status: MemoryStatus
    let bins: [TimeSeries.Bin]

    public init(_ status: MemoryStatus, bins: [TimeSeries.Bin]) {
        self.status = status
        self.bins = bins
    }

    public var body: some View {
        ResourceTile("Memory pressure", value: status.label + (status.action.map { " · \($0)" } ?? "")) {
            LevelBand(bins, colors: pressureColors)
        }
    }
}

/// How memory pressure is drawn: normal, warning, critical.
public let pressureColors: [Color] = [.green, .orange, .red]
