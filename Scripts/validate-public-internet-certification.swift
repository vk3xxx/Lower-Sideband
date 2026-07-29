#!/usr/bin/env swift

import CryptoKit
import Foundation

struct DeliveryReport: Decodable {
    let phase: String
    let networkMode: String
    let automaticConnection: String
    let localDestination: String
    let destination: String
    let startedAt: Date
    let completedAt: Date?
    let expectedEachDirection: Int
    let outboundQueued: Int
    let outboundDelivered: Int
    let outboundFailed: Int
    let inboundReceived: Int
    let missingOutbound: [String]
    let missingInbound: [String]
    let duplicateInbound: [String]
    let inboundInOrder: Bool
    let expectedAttachmentsEachDirection: Int
    let inboundAttachmentsVerified: Int
    let attachmentIntegrityFailures: [String]
    let knownPath: Bool
    let deliveryTimeouts: Int
}

struct Evidence: Encodable {
    let report: String
    let sha256: String
    let route: String
    let localDestination: String
    let remoteDestination: String
    let messagesEachDirection: Int
    let attachmentsEachDirection: Int
    let startedAt: Date
    let completedAt: Date
}

struct Certificate: Encodable {
    let schemaVersion = 1
    let generatedAt: Date
    let result: String
    let minimumMessagesEachDirection: Int
    let minimumIndependentRoutes: Int
    let totalMessagesEachDirection: Int
    let routes: [String]
    let evidence: [Evidence]
}

enum GateFailure: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let reason): reason }
    }
}

let environment = ProcessInfo.processInfo.environment
let minimumMessages = max(1, Int(environment["SIDEBAND_CERT_MIN_MESSAGES"] ?? "2500") ?? 2_500)
let minimumRoutes = max(1, Int(environment["SIDEBAND_CERT_MIN_ROUTES"] ?? "2") ?? 2)
let maximumTimeouts = max(0, Int(environment["SIDEBAND_CERT_MAX_TIMEOUTS"] ?? "0") ?? 0)
let arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    FileHandle.standardError.write(Data("Usage: validate-public-internet-certification.swift <report.json> [report.json ...]\n".utf8))
    exit(64)
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

do {
    var evidence: [Evidence] = []
    for path in arguments {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let report = try decoder.decode(DeliveryReport.self, from: data)
        guard report.phase == "complete" else { throw GateFailure.invalid("\(path): phase is \(report.phase), not complete") }
        guard ["internet", "public"].contains(report.networkMode) else { throw GateFailure.invalid("\(path): not an Internet-only run") }
        guard report.expectedEachDirection >= minimumMessages else { throw GateFailure.invalid("\(path): fewer than \(minimumMessages) messages each way") }
        guard report.outboundDelivered == report.expectedEachDirection,
              report.inboundReceived == report.expectedEachDirection,
              report.outboundQueued == 0, report.outboundFailed == 0 else {
            throw GateFailure.invalid("\(path): proof or receive totals do not match")
        }
        guard report.missingOutbound.isEmpty, report.missingInbound.isEmpty,
              report.duplicateInbound.isEmpty, report.inboundInOrder else {
            throw GateFailure.invalid("\(path): missing, duplicate, or out-of-order messages")
        }
        guard report.expectedAttachmentsEachDirection > 0,
              report.inboundAttachmentsVerified == report.expectedAttachmentsEachDirection,
              report.attachmentIntegrityFailures.isEmpty else {
            throw GateFailure.invalid("\(path): attachment integrity gate failed")
        }
        guard report.knownPath else { throw GateFailure.invalid("\(path): destination path was not retained") }
        guard report.deliveryTimeouts <= maximumTimeouts else { throw GateFailure.invalid("\(path): delivery timeout budget exceeded") }
        guard let completedAt = report.completedAt, completedAt >= report.startedAt else {
            throw GateFailure.invalid("\(path): completion timestamp is missing or invalid")
        }
        evidence.append(Evidence(
            report: url.standardizedFileURL.path,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            route: report.automaticConnection,
            localDestination: report.localDestination,
            remoteDestination: report.destination,
            messagesEachDirection: report.expectedEachDirection,
            attachmentsEachDirection: report.expectedAttachmentsEachDirection,
            startedAt: report.startedAt,
            completedAt: completedAt
        ))
    }
    let routes = Array(Set(evidence.map(\.route))).sorted()
    guard routes.count >= minimumRoutes else {
        throw GateFailure.invalid("Only \(routes.count) independent route description(s); \(minimumRoutes) required")
    }
    let certificate = Certificate(
        generatedAt: .now,
        result: "pass",
        minimumMessagesEachDirection: minimumMessages,
        minimumIndependentRoutes: minimumRoutes,
        totalMessagesEachDirection: evidence.reduce(0) { $0 + $1.messagesEachDirection },
        routes: routes,
        evidence: evidence
    )
    let outputURL = environment["SIDEBAND_CERTIFICATE_PATH"].map(URL.init(fileURLWithPath:))
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/public-internet-certification-\(ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: ""))")
            .appendingPathExtension("json")
    try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(certificate).write(to: outputURL, options: .atomic)
    print("PASS: \(outputURL.path)")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
