// license:GPLv3+

import QuartzCore
import SwiftUI

struct ControlCalibrationView: View {
    let calibration: CabinetCalibration
    let done: () -> Void
    @State private var confirmingClear = false

    var body: some View {
        ScrollView {
            panel
        }
        .confirmationDialog("Clear the Hand Recordings?", isPresented: $confirmingClear) {
            Button("Clear Recordings", role: .destructive) { calibration.clear() }
        }
        .task {
            while !Task.isCancelled {
                calibration.advance(at: CACurrentMediaTime())
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Record Hands").font(.title)
            Text("Record one take at a time beside the cabinet. Each take saves the tracked hand joints so the controls can be tuned from them. The table ignores your gestures while this is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("Take").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(HandTake.allCases) { gesture in
                        Button {
                            calibration.choose(gesture)
                        } label: {
                            Label(gesture.title, systemImage: calibration.selection == gesture
                                  ? "checkmark.circle.fill" : "circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityAddTraits(calibration.selection == gesture ? .isSelected : [])
                    }
                }
                .disabled(calibration.phase != .idle)
                Text(calibration.selection.instruction)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch calibration.phase {
                case .idle:
                    Button("Record Take", systemImage: "record.circle") {
                        calibration.start(at: CACurrentMediaTime())
                    }
                    .buttonStyle(.borderedProminent)
                case .gettingReady:
                    Label("Get Ready", systemImage: "timer")
                        .accessibilityAddTraits(.updatesFrequently)
                case .recording:
                    Label("Recording", systemImage: "record.circle")
                        .foregroundStyle(.red)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if calibration.phase != .idle {
                    Button("Cancel Take") { calibration.cancel() }
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            if let message = calibration.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Recording starts after 2 seconds and runs for \(Int(calibration.selection.seconds)) seconds. The next take is picked after each save.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("\(calibration.takeCount) takes saved")
                    .font(.headline)
                Text("The takes stay on this device in Files under VPX Vision, in Hand Recordings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("Clear Recordings", role: .destructive) { confirmingClear = true }
                    .disabled(calibration.takeCount == 0 || calibration.phase != .idle)
                Spacer()
                Button("Done", action: done)
            }
        }
        .padding(24)
    }
}
