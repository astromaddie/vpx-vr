// license:GPLv3+

import Foundation
import simd

@main
struct CalibrationCheck {
    @MainActor static func main() throws {
        let scratch = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        let file = scratch.appending(path: "calibration-report.json")
        let model = CabinetCalibration(url: file, build: "18")
        model.choose(.thumbTuck)
        model.start(at: 10)
        precondition(model.phase == .gettingReady)
        model.advance(at: 11.99)
        precondition(model.phase == .gettingReady)
        model.advance(at: 12)
        precondition(model.phase == .recording)
        let knob: SIMD3<Float> = [0, 0, 0]
        let layout = CabinetControlsLayout(plunger: knob, usesWristGestures: true)
        let sample = CabinetHandSample(palm: [0, 0, 0.06], plungerPose: .grab)
        func joint(_ point: SIMD3<Float>, tracked: Bool = true) -> CabinetHandJoint {
            .init(point: point, isTracked: tracked)
        }
        let metrics = CalibrationMetrics(
            side: .right, sample: sample, layout: layout, wrist: joint([0, 0, 0.06]),
            palm: joint(.zero), index: joint([-0.03, 0, 0]), little: joint([0.03, 0, 0]),
            indexTip: joint([-0.03, 0, -0.07]), thumb: joint([0, -0.015, 0], tracked: false)
        )
        precondition(!metrics.thumbTipTracked && metrics.palmDownDegrees == 0)
        precondition(metrics.thumbBelowPalmMM == 15 && metrics.thumbAcrossPalmPercent == 50)
        precondition(metrics.plungerFrontMM == 60 && metrics.plungerDecision == "grab")
        var controls = CabinetHandControls(layout: layout)
        let events = controls.update(.right, sample: sample, at: 12.03)
        precondition(events == [.pullPlunger(0)])
        model.observe(side: .right, at: 12.03, sample: sample, metrics: metrics, events: events)
        model.observe(side: .right, at: 12.04, sample: sample, metrics: metrics, events: [])
        model.observeSystemEvents(at: 12.2, events: controls.expire(at: 12.2))
        model.advance(at: 17)
        precondition(model.phase == .idle && model.selection == .pinch && model.attemptCount == 1)
        let data = try Data(contentsOf: file)
        let report = try JSONDecoder().decode(CabinetCalibration.Report.self, from: data)
        precondition(report.schema == 1 && report.build == "18")
        let attempt = report.attempts[0]
        precondition(attempt.gesture == .thumbTuck && attempt.frames.count == 2)
        precondition(attempt.frames[0].ms == 30 && attempt.frames[0].events == ["plungerHold:0"])
        precondition(attempt.frames[1].hand == "system" && attempt.frames[1].events == ["plungerCancel"])
        precondition(CabinetCalibration(url: file, build: "18").attemptCount == 1)
        precondition(CabinetCalibration(url: file, build: "19").attemptCount == 0)
        model.start(at: 20)
        model.advance(at: 22)
        model.cancel()
        precondition(model.attemptCount == 1)
        model.start(at: 30)
        model.advance(at: 37)
        precondition(model.attemptCount == 1 && model.message?.hasPrefix("No hand tracking") == true)
        for trial in 0..<20 {
            let t = 100 + Double(trial) * 10
            model.start(at: t)
            model.advance(at: t + 2)
            model.observe(side: .right, at: t + 2.1, sample: sample, metrics: metrics, events: [])
            model.advance(at: t + 7)
        }
        precondition(model.attemptCount == 18)
        model.clear()
        precondition(model.attemptCount == 0 && !FileManager.default.fileExists(atPath: file.path))
        print("Calibration passed: countdown, live recognizer events, derived metrics, bounded sampling, JSON, cancel and clear")
    }
}
