// license:GPLv3+

import Foundation
import os
import simd

/// Labelled hand recordings for tuning the recognizers offline.
enum HandTake: String, CaseIterable, Identifiable, Codable {
    case rest, lightShoveLeft, firmShoveLeft, lightShoveRight, firmShoveRight
    case lightShoveForward, firmShoveForward, leftSlaps, rightSlaps, flipDuringShoves
    case holdLeftFlipper, holdRightFlipper, quickFlips, reposition, thumbTuck, pinch

    var id: Self { self }

    var title: String {
        switch self {
        case .rest: "Resting Hands"
        case .lightShoveLeft: "Light Shoves Left"
        case .firmShoveLeft: "Firm Shoves Left"
        case .lightShoveRight: "Light Shoves Right"
        case .firmShoveRight: "Firm Shoves Right"
        case .lightShoveForward: "Light Shoves Forward"
        case .firmShoveForward: "Firm Shoves Forward"
        case .leftSlaps: "Left Hand Slaps"
        case .rightSlaps: "Right Hand Slaps"
        case .flipDuringShoves: "Flip During Shoves"
        case .holdLeftFlipper: "Hold Left Flipper"
        case .holdRightFlipper: "Hold Right Flipper"
        case .quickFlips: "Quick Flips"
        case .reposition: "Move Hands Around"
        case .thumbTuck: "Thumb Tuck Pull"
        case .pinch: "Pinch Pull"
        }
    }

    var instruction: String {
        switch self {
        case .rest: "Rest your hands where you normally play and keep them still."
        case .lightShoveLeft: "Hands on the cabinet sides. Give three light shoves to your left, resting between them."
        case .firmShoveLeft: "Hands on the cabinet sides. Give three firm shoves to your left, resting between them."
        case .lightShoveRight: "Hands on the cabinet sides. Give three light shoves to your right, resting between them."
        case .firmShoveRight: "Hands on the cabinet sides. Give three firm shoves to your right, resting between them."
        case .lightShoveForward: "Hands on the cabinet sides. Give three light shoves away from you, resting between them."
        case .firmShoveForward: "Hands on the cabinet sides. Give three firm shoves away from you, resting between them."
        case .leftSlaps: "Slap the left side of the cabinet with your left hand: light, medium, then hard."
        case .rightSlaps: "Slap the right side of the cabinet with your right hand: light, medium, then hard."
        case .flipDuringShoves: "Shove the cabinet a few times and flip either flipper in the middle of each shove."
        case .holdLeftFlipper: "Flick and hold the left flipper for about five seconds, then let go."
        case .holdRightFlipper: "Flick and hold the right flipper for about five seconds, then let go."
        case .quickFlips: "Flip both flippers the way you do during play."
        case .reposition: "Move your hands around the cabinet without flipping or shoving: reach for Start, slide along the sides, lift off and come back."
        case .thumbTuck: "Hold your palm down by the plunger. Tuck your thumb, pull, then release."
        case .pinch: "Pinch by the plunger, pull, then release."
        }
    }

    var seconds: Double {
        switch self {
        case .rest: 5
        case .holdLeftFlipper, .holdRightFlipper, .flipDuringShoves, .reposition: 8
        default: 6
        }
    }
}

/// One recorded take. Samples are integer rows so the file stays small:
/// side (0 left, 1 right), time in tenths of a millisecond from the start,
/// then for a tracked hand a bit mask of tracked joints, the anchor origin
/// and every joint in `CabinetJoint` order, in tenths of a millimetre in
/// cabinet space. A row with only side and time means the hand wasn't tracked.
struct CabinetHandRecording: Codable {
    static let schema = 3
    static let invalid = Int(Int32.max)

    var schema = Self.schema
    var build: String
    var take: HandTake
    var seconds: Double
    var layout: CabinetControlsLayout
    var samples: [[Int]] = []
    /// What the recognizers decided live: time in milliseconds and the input.
    var events: [String] = []

    static func row(side: CabinetHandSide, time: Double, frame: CabinetHandFrame?) -> [Int] {
        var row = [side == .left ? 0 : 1, Int((time * 10_000).rounded())]
        guard let frame else { return row }
        var mask = 0
        for (index, joint) in frame.joints.enumerated() where joint.isTracked { mask |= 1 << index }
        row.append(mask)
        func append(_ point: SIMD3<Float>) {
            for value in [point.x, point.y, point.z] {
                row.append(value.isFinite && abs(value) < 100 ? Int((value * 10_000).rounded()) : invalid)
            }
        }
        append(frame.origin)
        frame.joints.forEach { append($0.point) }
        return row
    }

    struct Sample {
        let side: CabinetHandSide
        let time: Double
        let frame: CabinetHandFrame?
    }

    var decoded: [Sample] {
        let count = CabinetJoint.allCases.count
        return samples.compactMap { row in
            guard row.count >= 2 else { return nil }
            let side: CabinetHandSide = row[0] == 0 ? .left : .right
            let time = Double(row[1]) / 10_000
            guard row.count == 3 + 3 * (count + 1) else { return Sample(side: side, time: time, frame: nil) }
            func point(_ at: Int) -> SIMD3<Float> {
                SIMD3((0..<3).map { row[at + $0] == Self.invalid ? Float.nan : Float(row[at + $0]) / 10_000 })
            }
            let joints = (0..<count).map { CabinetHandJoint(point: point(6 + 3 * $0), isTracked: row[2] & (1 << $0) != 0) }
            return Sample(side: side, time: time, frame: CabinetHandFrame(origin: point(3), joints: joints))
        }
    }

    static func describe(_ event: CabinetInput) -> String {
        switch event {
        case let .flipper(side, pressed): "\(side == .left ? "left" : "right") flipper \(pressed ? "down" : "up")"
        case .insertCoin: "coin"
        case .pressStart: "start"
        case .pressLaunchBall: "launch ball"
        case let .shove(acceleration, update):
            String(format: "shove%@ %.1f, %.1f m/s2", update ? " update" : "", acceleration.x, acceleration.y)
        case let .pullPlunger(amount): String(format: "plunger hold %.0f%%", amount * 100)
        case let .releasePlunger(amount): String(format: "plunger release %.0f%%", amount * 100)
        case .cancelPlunger: "plunger cancel"
        }
    }
}

/// Collects a take from the hand-tracking thread. Any thread can call it.
final class CabinetHandRecorder: @unchecked Sendable {
    private struct State {
        var recording: CabinetHandRecording?
        var start = 0.0
        var end = 0.0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    static let sampleLimit = 4000

    func begin(_ take: HandTake, build: String, layout: CabinetControlsLayout, from start: Double) {
        state.withLock {
            $0 = State(recording: CabinetHandRecording(build: build, take: take, seconds: take.seconds, layout: layout),
                       start: start, end: start + take.seconds)
        }
    }

    func record(_ side: CabinetHandSide, at time: Double, frame: CabinetHandFrame?, events: [CabinetInput]) {
        state.withLock { state in
            guard state.recording != nil, time >= state.start, time < state.end,
                  state.recording!.samples.count < Self.sampleLimit else { return }
            state.recording!.samples.append(CabinetHandRecording.row(side: side, time: time - state.start, frame: frame))
            for event in events {
                state.recording!.events.append(String(format: "%.0f ms: ", (time - state.start) * 1000)
                                               + CabinetHandRecording.describe(event))
            }
        }
    }

    func cancel() {
        state.withLock { $0 = State() }
    }

    /// The finished take, once its time is up.
    func finish(at time: Double) -> CabinetHandRecording? {
        state.withLock { state in
            guard state.recording != nil, time >= state.end else { return nil }
            defer { state = State() }
            return state.recording
        }
    }
}
