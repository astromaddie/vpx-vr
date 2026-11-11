// license:GPLv3+

import Foundation
import simd

/// Records a take through the calibration model, reads the file back and
/// replays it through the hand controls.
@main
struct CalibrationCheck {
    @MainActor static func main() throws {
        let scratch = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        let folder = scratch.appending(path: CabinetCalibration.folder(build: "30"))
        try? FileManager.default.removeItem(at: folder)
        let model = CabinetCalibration(folder: folder, build: "30")
        let layout = CabinetControlsLayout(usesWristGestures: true)
        model.layout = layout
        model.choose(.firmShoveRight)
        model.start(at: 10)
        precondition(model.phase == .gettingReady)
        model.advance(at: 11.99)
        precondition(model.phase == .gettingReady)
        model.advance(at: 12)
        precondition(model.phase == .recording)

        // A right hand with every joint placed, the knuckles estimated and the
        // thumb tip invalid, then one untracked sample.
        func frame(at wrist: SIMD3<Float>) -> CabinetHandFrame {
            let joints = CabinetJoint.allCases.map { joint -> CabinetHandJoint in
                switch joint {
                case .wrist: .init(point: wrist, isTracked: true)
                case .forearmArm: .init(point: wrist + [0, 0, 0.25], isTracked: true)
                case .forearmWrist: .init(point: wrist + [0, 0, 0.01], isTracked: true)
                case .thumbTip: .init(point: [.nan, 0, 0], isTracked: false)
                default: .init(point: wrist + [Float(joint.rawValue) * 0.001, 0, -0.08], isTracked: false)
                }
            }
            return CabinetHandFrame(origin: wrist, joints: joints)
        }
        let rest = layout.flipper(.right) + [0.04, 0.03, 0.06]
        for step in 0..<40 {
            let x = step < 25 ? 0 : -0.005 * Float(step - 24)
            model.recorder.record(.right, at: 12 + Double(step) * 0.011, frame: frame(at: rest + [x, 0, 0]),
                                  events: step == 30 ? [.shove([-3, 0], update: false)] : [])
        }
        model.recorder.record(.left, at: 12.5, frame: nil, events: [])
        model.recorder.record(.left, at: 19, frame: frame(at: rest), events: [])
        model.advance(at: 12 + HandTake.firmShoveRight.seconds)
        precondition(model.phase == .idle && model.takeCount == 1, model.message ?? "")
        precondition(model.selection == .lightShoveForward)

        let file = folder.appending(path: "01 Firm Shoves Right.json")
        let take = try JSONDecoder().decode(CabinetHandRecording.self, from: Data(contentsOf: file))
        precondition(take.take == .firmShoveRight && take.build == "30" && take.samples.count == 41)
        precondition(take.events == ["330 ms: shove -3.0, 0.0 m/s2"])
        let samples = take.decoded
        precondition(samples.last?.frame == nil && samples.last?.side == .left)
        let first = samples[0].frame!
        precondition(simd_distance(first[.wrist].point, rest) < 0.0001 && first[.wrist].isTracked)
        precondition(first[.thumbTip].estimatedPosition == nil && !first[.middleKnuckle].isTracked)
        let hand = CabinetHandSample(.right, frame: first, layout: take.layout)
        precondition(hand.wrist != nil && hand.forearmDirection != nil && hand.palm == nil)

        // The replay sees the same hand: a lone right hand moving inward from rest.
        var controls = CabinetHandControls(layout: take.layout)
        var shoves = 0
        for sample in samples where sample.side == .right {
            let events = controls.update(.right, sample: sample.frame.map { CabinetHandSample(.right, frame: $0, layout: take.layout) },
                                         at: sample.time)
            shoves += events.filter { if case .shove(_, false) = $0 { true } else { false } }.count
        }
        precondition(shoves == 1, "Replay shoves: \(shoves)")
        print("Hand recording passed: timed take, compact rows with tracked flags and invalid joints, file per take, replay through the recognizers")
    }
}
