import AllwardCore
import AllwardMultiplexer
import Foundation

/// The real numbers the diagnostics surface reports. Every field has a live
/// source; nothing here is a placeholder, because a diagnostics screen that
/// invents a zero is worse than one that names an absent source.
public struct DiagnosticsInputs: Sendable {
    public struct ProtocolTally: Sendable {
        public var accepted: Int
        public var ignoredUnknownFrames: Int
        public var rejectedBounds: Int
        public var duplicateSequences: Int
        public var staleEpochs: Int

        public init(
            accepted: Int = 0, ignoredUnknownFrames: Int = 0, rejectedBounds: Int = 0,
            duplicateSequences: Int = 0, staleEpochs: Int = 0
        ) {
            self.accepted = accepted
            self.ignoredUnknownFrames = ignoredUnknownFrames
            self.rejectedBounds = rejectedBounds
            self.duplicateSequences = duplicateSequences
            self.staleEpochs = staleEpochs
        }
    }

    public struct RendererTally: Sendable {
        public var framesSubmitted: Int
        public var monochromeAtlasOccupancy: Double
        public var colorAtlasOccupancy: Double
        /// Advances whenever an atlas is rebuilt or evicted, so a reader can
        /// tell a fresh occupancy reading from a repeated one.
        public var atlasGeneration: Generation

        public init(
            framesSubmitted: Int = 0, monochromeAtlasOccupancy: Double = 0,
            colorAtlasOccupancy: Double = 0, atlasGeneration: Generation = .initial
        ) {
            self.framesSubmitted = framesSubmitted
            self.monochromeAtlasOccupancy = monochromeAtlasOccupancy
            self.colorAtlasOccupancy = colorAtlasOccupancy
            self.atlasGeneration = atlasGeneration
        }
    }

    public var protocolTally: ProtocolTally
    public var renderer: RendererTally
    public var adapterHealth: AdapterHealth
    public var adapterRoute: String?
    public var adapterRouteReason: String?
    /// Absent when the Developer ID publisher endpoint is not listening. That
    /// is a real state, not a zero.
    public var publisherEndpointPath: String?
    public var activePublishers: Int
    public var mcpSocketPath: String?
    public var mcpListening: Bool
    public var connectionAttempts: Int
    public var lastConnectionCause: String?

    public init(
        protocolTally: ProtocolTally = ProtocolTally(),
        renderer: RendererTally = RendererTally(),
        adapterHealth: AdapterHealth = .none,
        adapterRoute: String? = nil,
        adapterRouteReason: String? = nil,
        publisherEndpointPath: String? = nil,
        activePublishers: Int = 0,
        mcpSocketPath: String? = nil,
        mcpListening: Bool = false,
        connectionAttempts: Int = 0,
        lastConnectionCause: String? = nil
    ) {
        self.protocolTally = protocolTally
        self.renderer = renderer
        self.adapterHealth = adapterHealth
        self.adapterRoute = adapterRoute
        self.adapterRouteReason = adapterRouteReason
        self.publisherEndpointPath = publisherEndpointPath
        self.activePublishers = activePublishers
        self.mcpSocketPath = mcpSocketPath
        self.mcpListening = mcpListening
        self.connectionAttempts = connectionAttempts
        self.lastConnectionCause = lastConnectionCause
    }
}
