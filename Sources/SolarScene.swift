import SwiftUI
import RealityKit
import UIKit
import QuartzCore

struct SolarSceneView: UIViewRepresentable {
    let reading: ReadingSnapshot?
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeCoordinator() -> SolarSceneController { SolarSceneController() }
    func makeUIView(context: Context) -> ARView {
        let view = SolarRenderView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.sceneController = context.coordinator
        view.renderOptions.formUnion([.disableMotionBlur, .disableDepthOfField, .disableCameraGrain])
        view.environment.background = .color(UIColor(red: 0.055, green: 0.064, blue: 0.064, alpha: 1))
        context.coordinator.install(in: view)
        view.accessibilityLabel = "Interactive solar home"
        view.isAccessibilityElement = true
        return view
    }
    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.update(reading, reduceMotion: reduceMotion, isActive: isActive)
        view.accessibilityValue = reading.map { "\($0.mode) mode. Load \(($0.values["Load power"] ?? 0).formatted(.number.precision(.fractionLength(0)))) watts." } ?? "Offline"
    }
    static func dismantleUIView(_ view: ARView, coordinator: SolarSceneController) { coordinator.stop() }
}

final class SolarRenderView: ARView {
    weak var sceneController: SolarSceneController?
    override func layoutSubviews() {
        super.layoutSubviews()
        sceneController?.positionLabels()
    }
}

final class SolarSceneController: NSObject, UIGestureRecognizerDelegate {
    private let anchor = AnchorEntity(world: .zero)
    private let home = Entity()
    private let camera = PerspectiveCamera()
    private let mint = UIColor(red: 0.27, green: 0.89, blue: 0.66, alpha: 1)
    private let blue = UIColor(red: 0.35, green: 0.66, blue: 1, alpha: 1)
    private var windows: [ModelEntity] = []
    private var windowLights: [PointLight] = []
    private var panels: [ModelEntity] = []
    private var batteryFill: ModelEntity?
    private var timer: Timer?
    private var energy = LiveEnergyState(nil)
    private var appliedEnergy: LiveEnergyState?
    private var meshes: [BoxGeometry: MeshResource] = [:]
    private struct BoxGeometry: Hashable { let size: SIMD3<Float>; let radius: Float }
    var isAnimating: Bool { timer != nil }
    private var yaw: Float = 0
    private var startYaw: Float = 0
    private var routes: [[SIMD3<Float>]] = []
    private var particles: [[ModelEntity]] = []
    private var trails: [[ModelEntity]] = []
    private weak var view: ARView?
    private var labels: [(UILabel, SIMD3<Float>)] = []
    private let concrete = SimpleMaterial(color: UIColor(white: 0.72, alpha: 1), roughness: 0.75, isMetallic: false)
    private let charcoal = SimpleMaterial(color: UIColor(white: 0.09, alpha: 1), roughness: 0.5, isMetallic: false)
    private let silver = SimpleMaterial(color: UIColor(white: 0.45, alpha: 1), roughness: 0.35, isMetallic: true)
    private let solar = SimpleMaterial(color: UIColor(red: 0.055, green: 0.16, blue: 0.3, alpha: 1), roughness: 0.22, isMetallic: true)

    @discardableResult private func box(_ size: SIMD3<Float>, _ at: SIMD3<Float>, _ material: any RealityKit.Material,
                     parent: Entity? = nil, radius: Float = 0.01) -> ModelEntity {
        let geometry = BoxGeometry(size: size, radius: radius)
        let mesh = meshes[geometry] ?? .generateBox(size: size, cornerRadius: radius)
        meshes[geometry] = mesh
        let node = ModelEntity(mesh: mesh, materials: [material])
        node.position = at
        (parent ?? home).addChild(node)
        return node
    }
    func install(in view: ARView) {
        self.view = view
        anchor.addChild(home)
        view.scene.addAnchor(anchor)
        camera.camera.fieldOfViewInDegrees = 35
        camera.look(at: [0, 0.8, 0], from: [4.7, 4.2, 5.9], relativeTo: nil)
        anchor.addChild(camera)
        let key = DirectionalLight()
        key.light.intensity = 4200
        key.shadow = .init(shadowProjection: .automatic(maximumDistance: 8), depthBias: 1)
        key.look(at: .zero, from: [-3, 7, 5], relativeTo: nil)
        anchor.addChild(key)
        let fill = DirectionalLight()
        fill.light.intensity = 1800
        fill.light.color = UIColor(red: 0.7, green: 0.85, blue: 1, alpha: 1)
        fill.look(at: .zero, from: [4, 3, -3], relativeTo: nil)
        anchor.addChild(fill)
        buildHome()
        buildRoutes()
        buildLabels(in: view)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(rotate(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }
    private func buildHome() {
        // The model is real geometry, with separate roof, glass, solar cells and equipment.
        box([4.0, 0.12, 3.2], [0, -0.08, 0], charcoal, radius: 0.08)
        box([3.85, 0.04, 3.05], [0, 0, 0], SimpleMaterial(color: UIColor(white: 0.23, alpha: 1), roughness: 0.9, isMetallic: false))
        box([2.25, 0.84, 1.7], [0.25, 0.47, -0.15], concrete)
        box([2.48, 0.10, 1.92], [0.25, 0.92, -0.15], silver)
        box([1.40, 0.86, 1.56], [0.64, 1.40, -0.20], concrete)
        box([1.62, 0.08, 1.78], [0.64, 1.86, -0.20], charcoal)
        box([0.10, 0.74, 0.10], [-0.78, 1.36, 0.52], concrete)
        box([0.70, 0.08, 1.75], [-0.52, 1.82, -0.14], concrete)
        box([0.68, 0.04, 1.42], [-0.54, 1.0, -0.18], charcoal)
        for x: Float in [-0.85, -0.21] {
            box([0.025, 0.27, 1.45], [x, 1.17, -0.12], silver)
        }
        box([0.69, 0.025, 0.025], [-0.53, 1.32, 0.59], silver)
        box([0.69, 0.025, 0.025], [-0.53, 1.32, -0.84], silver)
        box([1.32, 0.65, 0.03], [0.61, 0.50, 0.713], charcoal)
        box([1.14, 0.63, 0.03], [0.64, 1.41, 0.598], charcoal)
        for (y, z, x, width): (Float, Float, Float, Float) in [(0.5, 0.735, 0.61, 1.22), (1.41, 0.62, 0.64, 1.04)] {
            let glass = box([width, 0.53, 0.01], [x, y, z], UnlitMaterial(color: UIColor(white: 0.13, alpha: 1)))
            windows.append(glass)
            let glow = PointLight()
            glow.light.color = UIColor(red: 1, green: 0.74, blue: 0.38, alpha: 1)
            glow.light.intensity = 0
            glow.light.attenuationRadius = 1.1
            glow.position = [x, y, z + 0.12]
            home.addChild(glow)
            windowLights.append(glow)
            for offset in [-width / 6, width / 6] {
                box([0.025, 0.57, 0.018], [x + offset, y, z + 0.01], charcoal)
            }
        }
        box([0.44, 0.74, 0.035], [-0.57, 0.46, 0.714], charcoal)
        box([0.025, 0.15, 0.025], [-0.43, 0.45, 0.747], silver)
        for step in 0..<3 {
            box([0.58, 0.035, 0.17], [-0.58, 0.03 + Float(step) * 0.035, 1.17 - Float(step) * 0.16], concrete)
        }
        // Slatted side cladding gives the miniature depth at phone scale.
        for index in 0..<13 {
            box([0.022, 0.70, 0.08], [1.39, 1.38, -0.80 + Float(index) * 0.10], charcoal)
        }
        let rack = Entity()
        rack.position = [0.54, 2.04, -0.20]
        rack.orientation = simd_quatf(angle: 0.22, axis: [1, 0, 0])
        home.addChild(rack)
        for row in 0..<2 {
            for column in 0..<3 {
                let x = Float(column - 1) * 0.44
                let z = (Float(row) - 0.5) * 0.68
                box([0.42, 0.045, 0.64], [x, 0, z], silver, parent: rack)
                let panel = box([0.39, 0.012, 0.61], [x, 0.03, z], solar, parent: rack)
                panels.append(panel)
                for cell in 1..<4 {
                    box([0.002, 0.003, 0.59], [x - 0.195 + Float(cell) * 0.098, 0.04, z], silver, parent: rack, radius: 0)
                }
                for cell in 1..<6 {
                    box([0.38, 0.003, 0.002], [x, 0.04, z - 0.305 + Float(cell) * 0.102], silver, parent: rack, radius: 0)
                }
            }
        }
        box([0.37, 0.75, 0.27], [-1.35, 0.40, 0.45], concrete, radius: 0.035)
        box([0.28, 0.59, 0.018], [-1.35, 0.40, 0.595], charcoal)
        batteryFill = box([0.20, 0.49, 0.02], [-1.35, 0.40, 0.61], UnlitMaterial(color: mint))
        for index in 0..<4 {
            box([0.21, 0.012, 0.025], [-1.35, 0.25 + Float(index) * 0.10, 0.63], charcoal)
        }
        box([0.28, 0.38, 0.15], [-0.92, 0.6, -0.15], silver, radius: 0.025)
        box([0.16, 0.05, 0.015], [-0.92, 0.7, -0.065], UnlitMaterial(color: mint))
        box([0.14, 0.14, 0.07], [-0.15, 0.25, 0.745], silver)
        box([0.04, 0.02, 0.015], [-0.15, 0.27, 0.785], UnlitMaterial(color: mint))
        box([0.035, 1.04, 0.035], [1.73, 0.53, -1.18], silver)
        box([0.40, 0.035, 0.035], [1.73, 1.04, -1.18], silver)
        for x: Float in [1.58, 1.73, 1.88] {
            box([0.045, 0.09, 0.045], [x, 1.10, -1.18], concrete)
        }
        for x: Float in [-1.62, 1.63] {
            box([0.28, 0.15, 0.28], [x, 0.08, 1.13], charcoal)
            let plant = ModelEntity(mesh: .generateSphere(radius: 0.16), materials: [SimpleMaterial(color: UIColor(red: 0.18, green: 0.32, blue: 0.20, alpha: 1), roughness: 1, isMetallic: false)])
            plant.position = [x, 0.25, 1.13]
            home.addChild(plant)
            plant.scale = [0.9, 1.3, 0.9]
            for offset: Float in [-0.08, 0.07] {
                let leaf = ModelEntity(mesh: .generateSphere(radius: 0.10), materials: plant.model?.materials ?? [])
                leaf.position = [x + offset, 0.24, 1.13 + offset]
                home.addChild(leaf)
            }
        }
        for index in 0..<4 {
            box([0.42, 0.015, 0.15], [-0.58, 0.03, 1.32 + Float(index) * 0.06], concrete, radius: 0.003)
        }
    }
    private func buildRoutes() {
        routes = [
            [[0.14, 1.90, 0.47], [-0.91, 1.90, 0.47], [-1.08, 0.55, 0.47], [-1.08, 0.55, -0.15]],
            [[-1.155, 0.25, 0.45], [-1.08, 0.25, 0.45], [-1.08, 0.55, 0.45], [-1.08, 0.55, -0.15]],
            [[1.73, 0.97, -1.18], [1.73, 0.07, -1.18], [1.73, 0.07, 1.02], [-1.08, 0.07, 1.02], [-1.08, 0.55, 1.02], [-1.08, 0.55, -0.15]],
            [[-0.92, 0.55, -0.055], [-0.92, 0.08, 0.93], [-0.15, 0.08, 0.93], [-0.15, 0.25, 0.93], [-0.15, 0.25, 0.79]]
        ]
        let dotMesh = MeshResource.generateSphere(radius: 0.028)
        for points in routes {
            var segments: [ModelEntity] = []
            for index in 0..<(points.count - 1) {
                let from = points[index], to = points[index + 1]
                let difference = to - from
                let length = simd_length(difference)
                let wire = box([0.013, 0.013, length], (from + to) / 2, UnlitMaterial(color: UIColor(white: 0.17, alpha: 1)), radius: 0)
                wire.orientation = simd_quatf(from: [0, 0, 1], to: difference / length)
                segments.append(wire)
            }
            trails.append(segments)
            var dots: [ModelEntity] = []
            for _ in 0..<3 {
                let dot = ModelEntity(mesh: dotMesh, materials: [UnlitMaterial(color: mint)])
                dot.isEnabled = false
                home.addChild(dot)
                dots.append(dot)
            }
            particles.append(dots)
        }
    }
    private func buildLabels(in view: ARView) {
        let positions: [SIMD3<Float>] = [[0.54, 2.48, -0.20], [-1.82, 0.85, 0.55], [1.73, 1.45, -1.18], [0.50, 0.35, 1.45]]
        for point in positions {
            let label = UILabel()
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.numberOfLines = 2
            label.textAlignment = .center
            label.textColor = .white
            label.backgroundColor = UIColor(white: 0.06, alpha: 0.92)
            label.layer.cornerRadius = 7
            label.layer.borderWidth = 0.5
            label.layer.borderColor = UIColor(white: 0.3, alpha: 1).cgColor
            label.clipsToBounds = true
            label.isHidden = true
            label.bounds.size = CGSize(width: 72, height: 38)
            view.addSubview(label)
            labels.append((label, point))
        }
    }
    fileprivate func positionLabels() {
        guard let view, view.bounds.width > 0 else { return }
        for (label, point) in labels {
            guard let position = view.project(home.convert(position: point, to: nil)) else { label.isHidden = true; continue }
            label.isHidden = !energy.connected
            label.center = CGPoint(x: min(view.bounds.width - label.bounds.width / 2, max(label.bounds.width / 2, position.x)),
                                   y: min(view.bounds.height - label.bounds.height / 2, max(label.bounds.height / 2, position.y)))
        }
    }
    func update(_ reading: ReadingSnapshot?, reduceMotion: Bool, isActive: Bool = true) {
        let value = LiveEnergyState(reading)
        energy = value
        // Lifecycle and viewport signals pause live work, never the camera or house.
        if appliedEnergy != value {
            appliedEnergy = value
            let warmth = value.loadActive ? UIColor(red: 1, green: 0.74, blue: 0.38, alpha: 1) : UIColor(white: 0.13, alpha: 1)
            for window in windows { window.model?.materials = [UnlitMaterial(color: warmth)] }
            for light in windowLights { light.light.intensity = value.loadActive ? 70 : 0 }
            let panelColor = value.solarActive ? UIColor(red: 0.08, green: 0.32, blue: 0.55, alpha: 1) : UIColor(red: 0.055, green: 0.16, blue: 0.3, alpha: 1)
            for panel in panels { panel.model?.materials = [SimpleMaterial(color: panelColor, roughness: 0.22, isMetallic: true)] }
            batteryFill?.scale.y = max(0.01, value.batteryLevel)
            batteryFill?.position.y = 0.155 + 0.245 * max(0.01, value.batteryLevel)
            batteryFill?.model?.materials = [UnlitMaterial(color: value.connected ? mint : UIColor(white: 0.2, alpha: 1))]
            let active = [value.solarActive, value.batteryFlow != .idle, value.gridActive, value.loadActive]
            for route in routes.indices {
                let color = route == 2 ? blue : route == 3 ? UIColor(red: 1, green: 0.74, blue: 0.38, alpha: 1) : mint
                for wire in trails[route] { wire.model?.materials = [UnlitMaterial(color: active[route] ? color.withAlphaComponent(0.6) : UIColor(white: 0.17, alpha: 1))] }
                let material = UnlitMaterial(color: color)
                for dot in particles[route] { dot.model?.materials = [material] }
            }
        }
        let active = [value.solarActive, value.batteryFlow != .idle, value.gridActive, value.loadActive]
        for route in particles.indices {
            for dot in particles[route] { dot.isEnabled = isActive && active[route] && !reduceMotion }
        }
        if let reading {
            let values = reading.values
            let watts = abs((values["Battery charge current"] ?? 0) - (values["Battery discharge current"] ?? 0)) * (values["Battery voltage"] ?? 0)
            let estimate = watts.isFinite ? watts.formatted(.number.precision(.fractionLength(0))) : "—"
            let battery = value.batteryFlow == .idle ? "Battery\nIdle" : "\(value.batteryFlow == .charging ? "Charging" : "Battery")\n~\(estimate) W"
            let solarWatts = (values["PV charging power"] ?? 0).formatted(.number.precision(.fractionLength(0)))
            let loadWatts = (values["Load power"] ?? 0).formatted(.number.precision(.fractionLength(0)))
            let texts = ["Solar\n\(solarWatts) W", battery,
                         "Grid\n\(value.gridActive ? "Supplying" : "Standby")", "Load\n\(loadWatts) W"]
            for (index, entry) in labels.enumerated() {
                if entry.0.text != texts[index] { entry.0.text = texts[index] }
                entry.0.isHidden = false
            }
            positionLabels()
        } else { for (label, _) in labels { label.isHidden = true } }
        if isActive && !reduceMotion && active.contains(true) {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.animate() }
                }
            }
        } else { stop() }
    }
    private func animate() {
        let phase = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 2.4) / 2.4)
        for route in routes.indices {
            var points = routes[route]
            if route == 1 && energy.batteryFlow == .charging { points.reverse() }
            for (index, dot) in particles[route].enumerated() where dot.isEnabled {
                let t = (phase + Float(index) / 3).truncatingRemainder(dividingBy: 1) * Float(points.count - 1)
                let segment = min(points.count - 2, Int(t))
                dot.position = simd_mix(points[segment], points[segment + 1], SIMD3(repeating: t - Float(segment)))
            }
        }
    }
    @objc private func rotate(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { startYaw = yaw }
        yaw = startYaw + Float(gesture.translation(in: gesture.view).x) * 0.006
        home.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        positionLabels()
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.x) > abs(velocity.y)
    }
    func stop() { timer?.invalidate(); timer = nil }
}
