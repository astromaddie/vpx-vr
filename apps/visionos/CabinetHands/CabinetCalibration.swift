// license:GPLv3+

import Foundation
import Observation
import simd

enum CalibrationGesture: String, CaseIterable, Identifiable, Codable {
    case rest, rightFlipper, leftFlipper, thumbTuck, pinch, nudge

    var id: Self { self }
    var title: String {
        switch self {
        case .rest: "Resting Hands"
        case .rightFlipper: "Right Flipper"
        case .leftFlipper: "Left Flipper"
        case .thumbTuck: "Thumb Tuck Pull"
        case .pinch: "Pinch Pull"
        case .nudge: "Two-Fist Nudge"
        }
    }

    var instruction: String {
        switch self {
        case .rest: "Rest your hands where you normally play."
        case .rightFlipper: "Flick your right wrist inward the way you do during play."
        case .leftFlipper: "Flick your left wrist inward the way you do during play."
        case .thumbTuck: "Hold your palm down by the plunger. Tuck your thumb, pull, then release."
        case .pinch: "Pinch by the plunger, pull, then release."
        case .nudge: "Close both fists by the cabinet sides and move them together to nudge."
        }
    }
}

struct CalibrationMetrics: Codable {
    let thumbTipTracked: Bool
    let palmDownDegrees: Int?
    let trackedPalmJoints: Int
    let thumbIndexGapMM: Int?
    let thumbBelowPalmMM: Int?
    let thumbAcrossPalmPercent: Int?
    let wristInwardDegrees: Int?
    let plungerFrontMM: Int?
    let plungerOffsetMM: Int?
    let atSideRail: Bool
    let firmFist: Bool
    let plungerDecision: String

    init(side: CabinetHandSide, sample: CabinetHandSample, layout: CabinetControlsLayout,
         wrist: CabinetHandJoint, palm: CabinetHandJoint, index: CabinetHandJoint,
         little: CabinetHandJoint, indexTip: CabinetHandJoint, thumb: CabinetHandJoint) {
        thumbTipTracked = thumb.isTracked
        trackedPalmJoints = [wrist, palm, index, little].filter { $0.trackedPosition != nil }.count
        thumbIndexGapMM = Self.integer(thumb.estimatedPosition.flatMap { tip in
            indexTip.estimatedPosition.map { simd_distance(tip, $0) * 1000 }
        })
        var down: Float?
        var below: Float?
        var across: Float?
        if let wrist = wrist.estimatedPosition, let palm = palm.estimatedPosition,
           let index = index.estimatedPosition, let little = little.estimatedPosition {
            let span = little - index
            let normal = side.sign * simd_cross(-span, palm - wrist)
            if simd_length_squared(normal) > 1e-8 {
                let unitNormal = simd_normalize(normal)
                down = acos(min(max(-unitNormal.y, -1), 1)) * 180 / .pi
                if let tip = thumb.estimatedPosition {
                    below = simd_dot(tip - palm, unitNormal) * 1000
                    across = simd_dot(tip - index, span) / simd_length_squared(span) * 100
                }
            }
        }
        palmDownDegrees = Self.integer(down)
        thumbBelowPalmMM = Self.integer(below)
        thumbAcrossPalmPercent = Self.integer(across)
        if let direction = sample.fingerDirection, let forearm = sample.forearmDirection,
           simd_length_squared(forearm) > 1e-8 {
            let arm = simd_normalize(forearm)
            let inward = SIMD3<Float>(-side.sign, 0, 0)
            let lateral = inward - arm * simd_dot(inward, arm)
            wristInwardDegrees = simd_length_squared(lateral) > 0.1 && simd_dot(direction, arm) > 0
                ? Self.integer(atan2(simd_dot(direction, simd_normalize(lateral)),
                                     simd_dot(direction, arm)) * 180 / .pi)
                : nil
        } else {
            wristInwardDegrees = nil
        }
        if let position = sample.gripPosition {
            atSideRail = layout.isByNudgeRail(side, palm: position, margin: 0)
            let offset = layout.plunger.map { position - $0 }
            plungerFrontMM = Self.integer(offset.map { $0.z * 1000 })
            plungerOffsetMM = Self.integer(offset.map { simd_length(SIMD2($0.x, $0.y)) * 1000 })
        } else {
            atSideRail = false
            plungerFrontMM = nil
            plungerOffsetMM = nil
        }
        firmFist = sample.pose == .fist
        plungerDecision = switch sample.plungerPose {
        case .grab: "grab"
        case .release: "release"
        case .uncertain: "uncertain"
        }
    }

    static func integer(_ value: Float?) -> Int? {
        guard let value, value.isFinite, abs(value) < 100_000 else { return nil }
        return Int(value.rounded())
    }
}

@MainActor
@Observable
final class CabinetCalibration {
    enum Phase { case idle, gettingReady, recording }
    struct Frame: Codable {
        let ms: Int
        let hand: String
        let metrics: CalibrationMetrics?
        let lateralTravelMM: Int?
        let verticalTravelMM: Int?
        let events: [String]
    }
    struct Attempt: Codable {
        let gesture: CalibrationGesture
        let frames: [Frame]
    }
    struct Report: Codable {
        let schema: Int
        let build: String
        var attempts: [Attempt]
    }

    static let filename = "Control Calibration.json"
    private static let attemptLimit = 18
    private static let frameLimit = 600
    private static let preparationTime = 2.0
    private static let recordTime = 5.0

    private let url: URL
    private var report: Report
    private(set) var phase = Phase.idle
    private(set) var selection = CalibrationGesture.rest
    private(set) var message: String?
    @ObservationIgnored private var startTime: Double = 0
    @ObservationIgnored private var frames: [Frame] = []
    @ObservationIgnored private var lastFrame: [CabinetHandSide: Double] = [:]
    @ObservationIgnored private var origins: [CabinetHandSide: SIMD3<Float>] = [:]

    var attemptCount: Int { report.attempts.count }
    var isRecording: Bool { phase == .recording }

    init(url: URL, build: String) {
        self.url = url
        let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let previous = (fileSize ?? 0) <= 5_000_000
            ? (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Report.self, from: $0) }
            : nil
        if var previous, previous.schema == 1, previous.build == build,
           previous.attempts.allSatisfy({ $0.frames.count <= Self.frameLimit }) {
            previous.attempts = Array(previous.attempts.suffix(Self.attemptLimit))
            report = previous
        } else {
            report = Report(schema: 1, build: build, attempts: [])
        }
    }

    func choose(_ gesture: CalibrationGesture) {
        guard phase == .idle else { return }
        selection = gesture
    }

    func start(at time: Double) {
        guard phase == .idle else { return }
        startTime = time + Self.preparationTime
        message = nil
        phase = .gettingReady
    }

    func advance(at time: Double) {
        guard phase != .idle, time >= startTime else { return }
        if time < startTime + Self.recordTime {
            if phase != .recording { phase = .recording }
        } else {
            finish()
        }
    }

    func observe(side: CabinetHandSide, at time: Double, sample: CabinetHandSample?,
                 metrics: CalibrationMetrics?, events: [CabinetInput]) {
        guard isRecording, time >= startTime, time < startTime + Self.recordTime,
              frames.count < Self.frameLimit else { return }
        guard !events.isEmpty || time - (lastFrame[side] ?? -.infinity) >= 0.032 else { return }
        lastFrame[side] = time
        let position = sample?.gripPosition
        if origins[side] == nil { origins[side] = position }
        let travel = position.flatMap { palm in origins[side].map { palm - $0 } }
        frames.append(Frame(ms: Int(((time - startTime) * 1000).rounded()), hand: side == .left ? "left" : "right",
                            metrics: metrics, lateralTravelMM: CalibrationMetrics.integer(travel.map { $0.x * 1000 }),
                            verticalTravelMM: CalibrationMetrics.integer(travel.map { $0.y * 1000 }),
                            events: events.map(Self.describe)))
    }

    func observeSystemEvents(at time: Double, events: [CabinetInput]) {
        guard isRecording, !events.isEmpty, time >= startTime, time < startTime + Self.recordTime,
              frames.count < Self.frameLimit else { return }
        frames.append(Frame(ms: Int(((time - startTime) * 1000).rounded()), hand: "system",
                            metrics: nil, lateralTravelMM: nil, verticalTravelMM: nil, events: events.map(Self.describe)))
    }

    func cancel() {
        phase = .idle
        frames.removeAll(keepingCapacity: true)
        lastFrame.removeAll()
        origins.removeAll()
    }

    func clear() {
        guard phase == .idle else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            report.attempts = []
            message = "Calibration report cleared."
        } catch {
            message = "Couldn’t clear the calibration report."
        }
    }

    private func finish() {
        let captured = frames
        cancel()
        guard captured.contains(where: { $0.metrics != nil }) else {
            message = "No hand tracking samples. Keep your hands in view and try again."
            return
        }
        var updated = report
        updated.attempts.append(Attempt(gesture: selection, frames: captured))
        updated.attempts = Array(updated.attempts.suffix(Self.attemptLimit))
        do {
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            report = updated
            message = "Attempt saved to Files."
            if let next = CalibrationGesture.allCases.firstIndex(of: selection).map({ $0 + 1 }),
               CalibrationGesture.allCases.indices.contains(next) {
                selection = CalibrationGesture.allCases[next]
            }
        } catch {
            message = "Couldn’t save the calibration report."
        }
    }

    private nonisolated static func describe(_ event: CabinetInput) -> String {
        switch event {
        case let .flipper(side, pressed): "\(side == .left ? "left" : "right")Flipper:\(pressed ? "down" : "up")"
        case .insertCoin: "coin"
        case .pressStart: "start"
        case let .nudge(direction): "nudge:\(direction)"
        case let .pullPlunger(amount): "plungerHold:\(CalibrationMetrics.integer(amount * 100) ?? 0)"
        case let .releasePlunger(amount): "plungerRelease:\(CalibrationMetrics.integer(amount * 100) ?? 0)"
        case .cancelPlunger: "plungerCancel"
        }
    }
}
