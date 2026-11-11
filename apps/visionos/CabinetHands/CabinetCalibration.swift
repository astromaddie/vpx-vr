// license:GPLv3+

import Foundation
import Observation

/// Records labelled takes of the raw hand joints, one file per take, under
/// Documents/Hand Recordings/Build <n>. The Mac check replays them through the
/// recognizers.
@MainActor
@Observable
final class CabinetCalibration {
    enum Phase { case idle, gettingReady, recording }

    static func folder(build: String) -> String { "Hand Recordings/Build \(build)" }
    private static let preparationTime = 2.0

    private let folder: URL
    private let build: String
    @ObservationIgnored let recorder = CabinetHandRecorder()
    @ObservationIgnored var layout = CabinetControlsLayout()
    private(set) var phase = Phase.idle
    private(set) var selection = HandTake.rest
    private(set) var message: String?
    private(set) var takeCount = 0
    @ObservationIgnored private var startTime: Double = 0

    var isRecording: Bool { phase == .recording }

    init(folder: URL, build: String) {
        self.folder = folder
        self.build = build
        takeCount = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
    }

    func choose(_ take: HandTake) {
        guard phase == .idle else { return }
        selection = take
    }

    func start(at time: Double) {
        guard phase == .idle else { return }
        startTime = time + Self.preparationTime
        message = nil
        recorder.begin(selection, build: build, layout: layout, from: startTime)
        phase = .gettingReady
    }

    func advance(at time: Double) {
        guard phase != .idle, time >= startTime else { return }
        if time < startTime + selection.seconds {
            if phase != .recording { phase = .recording }
        } else if let take = recorder.finish(at: time) {
            phase = .idle
            save(take)
        }
    }

    func cancel() {
        phase = .idle
        recorder.cancel()
    }

    func clear() {
        guard phase == .idle else { return }
        do {
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            takeCount = 0
            message = "Recordings cleared."
        } catch {
            message = "Couldn’t clear the recordings."
        }
    }

    private func save(_ take: CabinetHandRecording) {
        guard take.samples.contains(where: { $0.count > 2 }) else {
            message = "No hand tracking samples. Keep your hands in view and try again."
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = String(format: "%02d %@.json", takeCount + 1, take.take.title)
            try JSONEncoder().encode(take).write(to: folder.appending(path: name), options: .atomic)
            takeCount += 1
            message = "\(take.take.title) saved."
            if let next = HandTake.allCases.firstIndex(of: selection).map({ $0 + 1 }),
               HandTake.allCases.indices.contains(next) {
                selection = HandTake.allCases[next]
            }
        } catch {
            message = "Couldn’t save the recording."
        }
    }
}
