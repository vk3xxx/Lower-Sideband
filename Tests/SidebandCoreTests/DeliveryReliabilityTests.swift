import Foundation
import Testing
@testable import SidebandCore

@Test func reliabilityIsHealthyWhenReadyAndClear() {
    let snapshot = DeliveryReliabilitySnapshot(
        networkReady: true,
        networkConnecting: false,
        automaticRecoveryEnabled: true,
        queuedCount: 0,
        awaitingProofCount: 0,
        deliveredCount: 42,
        failedCount: 0,
        deliveryTimeoutCount: 0,
        recoveredOutboundCount: 2,
        deferredKeepaliveCount: 0,
        deferredTunnelCount: 0,
        knownRouteCount: 4,
        activeLinkCount: 1,
        reconnectDelaySeconds: nil,
        lastNetworkReadyAt: .now,
        interfaces: [.init(id: "public-a", name: "Public A", endpoint: "gateway.example:4242", isReady: true, connectedAt: .now, lastPacketAt: .now)]
    )

    #expect(snapshot.health == .healthy)
    #expect(snapshot.recommendedAction == nil)
    #expect(snapshot.summary.contains("ready"))
}

@Test func reliabilityPrioritisesFailedDeliveryRecovery() {
    let snapshot = DeliveryReliabilitySnapshot(
        networkReady: false,
        networkConnecting: true,
        automaticRecoveryEnabled: true,
        queuedCount: 3,
        awaitingProofCount: 1,
        deliveredCount: 0,
        failedCount: 2,
        deliveryTimeoutCount: 2,
        recoveredOutboundCount: 0,
        deferredKeepaliveCount: 1,
        deferredTunnelCount: 1,
        knownRouteCount: 0,
        activeLinkCount: 0,
        reconnectDelaySeconds: 4,
        lastNetworkReadyAt: nil,
        interfaces: []
    )

    #expect(snapshot.health == .needsAttention)
    #expect(snapshot.recommendedAction?.contains("Reconnect") == true)
    #expect(snapshot.failedCount == 2)
}

@Test func reliabilityReportsAutomaticRecoveryCountdown() {
    let snapshot = DeliveryReliabilitySnapshot(
        networkReady: false,
        networkConnecting: true,
        automaticRecoveryEnabled: true,
        queuedCount: 1,
        awaitingProofCount: 0,
        deliveredCount: 0,
        failedCount: 0,
        deliveryTimeoutCount: 0,
        recoveredOutboundCount: 0,
        deferredKeepaliveCount: 0,
        deferredTunnelCount: 0,
        knownRouteCount: 0,
        activeLinkCount: 0,
        reconnectDelaySeconds: 8,
        lastNetworkReadyAt: nil,
        interfaces: []
    )

    #expect(snapshot.health == .recovering)
    #expect(snapshot.summary.contains("8 seconds"))
}
