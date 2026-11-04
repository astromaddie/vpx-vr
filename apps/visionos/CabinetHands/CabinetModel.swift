// license:GPLv3+

import RealityKit
import UIKit
import simd

@MainActor
final class CabinetModel {
    let root = Entity()
    private let start: ModelEntity
    private let coin: ModelEntity
    private let flippers: [(CabinetHandSide, ModelEntity, Entity)]
    private static let light = SimpleMaterial(color: .white, roughness: 0.27, isMetallic: false)
    private static let cabinet = SimpleMaterial(color: UIColor(red: 0.10, green: 0.14, blue: 0.18, alpha: 1),
                                                roughness: 0.53, isMetallic: false)
    private static let red = SimpleMaterial(color: .systemRed, roughness: 0.40, isMetallic: false)
    private static let green = SimpleMaterial(color: .systemGreen, roughness: 0.40, isMetallic: false)
    private static let gold = SimpleMaterial(color: .systemOrange, roughness: 0.40, isMetallic: true)

    init(layout: CabinetControlsLayout) {
        start = ModelEntity(mesh: .generateCylinder(height: 0.020, radius: 0.033), materials: [Self.green])
        start.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        start.position = layout.start - SIMD3(0, 0, 0.010)
        let coinFace = CabinetControlsLayout.coinFaceSize
        coin = Self.box([coinFace.x, coinFace.y, 0.024], at: layout.coin - SIMD3(0, 0, 0.014), material: Self.gold)
        coin.addChild(Self.box([0.010, 0.043, 0.005], at: [0, 0, 0.015], material: Self.cabinet))
        flippers = CabinetHandSide.allCases.map { side in
            let button = Self.box([0.025, 0.042, 0.060], at: layout.flipper(side), material: Self.red)
            let pivot = Entity()
            pivot.position = [side.sign * 0.105, -0.024, -0.22]
            pivot.addChild(Self.box([0.13, 0.027, 0.028], at: [-side.sign * 0.051, 0, 0], material: Self.red))
            return (side, button, pivot)
        }
        let playfield = SimpleMaterial(color: UIColor(red: 0.10, green: 0.29, blue: 0.39, alpha: 1),
                                       roughness: 0.57, isMetallic: false)
        let depth = layout.depth
        let centreZ = -depth / 2
        root.addChild(Self.box([layout.playfieldWidth, 0.020, layout.playfieldLength],
                               at: [0, -0.052, centreZ], material: playfield))
        root.addChild(Self.box([layout.width, 0.20, depth], at: [0, -0.154, centreZ], material: Self.cabinet))
        root.addChild(Self.box([layout.width, 0.25, 0.035], at: [0, -0.125, -0.0175], material: Self.cabinet))
        for side in CabinetHandSide.allCases {
            let x = side.sign * (layout.width / 2 - 0.012)
            root.addChild(Self.box([0.024, 0.07, depth], at: [x, -0.035, centreZ], material: Self.cabinet))
            for z: Float in [-0.14, -depth + 0.14] {
                root.addChild(Self.box([0.045, 0.68, 0.045], at: [x, -0.58, z], material: Self.cabinet))
            }
        }
        root.addChild(Self.box([layout.width, 0.37, 0.12], at: [0, 0.185, -depth + 0.06], material: Self.cabinet))
        root.addChild(Self.box([layout.width - 0.10, 0.21, 0.01], at: [0, 0.21, -depth + 0.125], material: playfield))
        for x: Float in [-0.14, 0, 0.14] {
            let bumper = ModelEntity(mesh: .generateCylinder(height: 0.028, radius: 0.045), materials: [Self.gold])
            bumper.position = [x, -0.027, centreZ - (x == 0 ? 0.17 : 0.07)]
            root.addChild(bumper)
        }

        root.addChild(start)
        root.addChild(coin)
        for (_, button, pivot) in flippers {
            root.addChild(button)
            root.addChild(pivot)
        }
        root.position = [0, -0.32, -0.72]
        show([])
    }

    func show(_ actions: Set<CabinetAction>) {
        for (side, button, pivot) in flippers {
            let pressed = actions.contains(side == .left ? .leftFlipper : .rightFlipper)
            button.model?.materials = [pressed ? Self.light : Self.red]
            pivot.orientation = simd_quatf(angle: side.sign * (pressed ? -0.4 : 0.28), axis: [0, 1, 0])
        }
        coin.model?.materials = [actions.contains(.addCredit) ? Self.light : Self.gold]
        start.model?.materials = [actions.contains(.start) ? Self.light : Self.green]
    }

    private static func box(_ size: SIMD3<Float>, at position: SIMD3<Float>, material: SimpleMaterial) -> ModelEntity {
        let box = ModelEntity(mesh: .generateBox(size: size, cornerRadius: min(size.x, size.y, size.z) * 0.12),
                              materials: [material])
        box.position = position
        return box
    }
}
