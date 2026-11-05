// license:GPLv3+

import QuartzCore
import SwiftUI

struct ControlCalibrationView: View {
    let calibration: CabinetCalibration
    let done: () -> Void
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Control Calibration").font(.title)
            Text("Record one attempt at a time beside the cabinet. The table will ignore game inputs while calibration is open.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Text("Gesture").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(CalibrationGesture.allCases) { gesture in
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
                    Button("Record Attempt", systemImage: "record.circle") {
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
                    Button("Cancel Attempt") { calibration.cancel() }
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
            if let message = calibration.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Recording starts after 2 seconds and runs for 5 seconds.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("\(calibration.attemptCount) attempts saved")
                    .font(.headline)
                Text("The report stays on this device in Files under VPX Vision.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("Clear Report", role: .destructive) { confirmingClear = true }
                    .disabled(calibration.attemptCount == 0 || calibration.phase != .idle)
                Spacer()
                Button("Done", action: done)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Clear the Calibration Report?", isPresented: $confirmingClear) {
            Button("Clear Report", role: .destructive) { calibration.clear() }
        }
        .task {
            while !Task.isCancelled {
                calibration.advance(at: CACurrentMediaTime())
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
