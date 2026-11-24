import AppKit
import SceneKit
import SwiftUI

struct RemotePose: Equatable {
    var yaw: Double
    var pitch: Double
}

struct RemoteRender: NSViewRepresentable {
    let profile: RemoteProfile
    let pose: RemotePose
    let selected: RemoteKey
    let pressed: RemoteKey?
    let animate: Bool
    let onProjection: ([RemoteKey: CGPoint]) -> Void
    let onSelect: (RemoteKey) -> Void
    let onDrag: (CGFloat, CGFloat) -> Void
    let onDragEnd: () -> Void

    func makeNSView(context: Context) -> RemoteSceneView {
        let view = RemoteSceneView(profile: profile)
        view.onSelect = onSelect
        view.onProjection = onProjection
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.apply(pose: pose, selected: selected, pressed: pressed, animate: false)
        return view
    }

    func updateNSView(_ view: RemoteSceneView, context: Context) {
        view.onSelect = onSelect
        view.onProjection = onProjection
        view.onDrag = onDrag
        view.onDragEnd = onDragEnd
        view.apply(pose: pose, selected: selected, pressed: pressed, animate: animate)
    }
}

@MainActor
final class RemoteSceneView: SCNView {
    private let assembly = SCNNode()
    private var keys: [RemoteKey: [SCNNode]] = [:]
    private var anchors: [RemoteKey: SCNNode] = [:]
    #if T1_EXPORT_REMOTE
    private var exportLegends: [ObjectIdentifier: [String: Any]] = [:]
    #endif
    private var oldPose: RemotePose?
    private var oldSelection: RemoteKey?
    private var oldPress: RemoteKey?
    private var mouseOrigin: NSPoint?
    private var lastDragPoint: NSPoint?
    private var lastProjection: [RemoteKey: CGPoint] = [:]
    private var projectionPending = false
    private var blinkTask: Task<Void, Never>?

    var onProjection: (([RemoteKey: CGPoint]) -> Void)?
    var onSelect: ((RemoteKey) -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    init(profile: RemoteProfile) {
        super.init(frame: .zero, options: nil)
        let stage = SCNScene()
        scene = stage
        stage.rootNode.addChildNode(assembly)
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        rendersContinuously = false
        preferredFramesPerSecond = 60

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = 4.47
        camera.camera?.zNear = 1
        camera.camera?.zFar = 36
        camera.position = SCNVector3(0, -0.20, 19)
        stage.rootNode.addChildNode(camera)
        pointOfView = camera

        installLight(in: stage, type: .ambient, color: .white, intensity: 610)
        installLight(in: stage, type: .directional, color: .white, intensity: 970, pitch: -0.48, yaw: -0.45)
        installLight(in: stage, type: .directional,
                     color: NSColor(srgbRed: 0.75, green: 0.82, blue: 1, alpha: 1),
                     intensity: 490, pitch: 0.55, yaw: 1.04)
        switch profile {
        case .t1: buildHardware()
        case .xiaomi: buildXiaomi()
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        scheduleProjection()
    }

    func apply(pose: RemotePose, selected: RemoteKey, pressed: RemoteKey?, animate: Bool) {
        guard oldPose != pose || oldSelection != selected || oldPress != pressed else { return }
        let shouldAnimate = animate && oldPose != nil
        if shouldAnimate {
            blinkTask?.cancel()
            isPlaying = true
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = shouldAnimate ? 0.32 : 0
        assembly.eulerAngles = SCNVector3(pose.pitch, pose.yaw, -0.035)
        for (key, nodes) in keys where key == oldSelection || key == selected || key == oldPress || key == pressed {
            let highlight = key == selected
            let held = key == pressed
            for node in nodes {
                guard let material = node.geometry?.firstMaterial else { continue }
                material.emission.contents = held ? Self.lit : highlight ? Self.selectedGlow : NSColor.black
                node.scale = held ? SCNVector3(0.93, 0.93, 0.9) : SCNVector3(1, 1, 1)
            }
        }
        SCNTransaction.commit()
        oldPose = pose
        oldSelection = selected
        oldPress = pressed
        needsDisplay = true
        scheduleProjection()
        if shouldAnimate {
            blinkTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(360))
                guard !Task.isCancelled else { return }
                self?.isPlaying = false
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseOrigin = convert(event.locationInWindow, from: nil)
        lastDragPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseOrigin else { return }
        let current = convert(event.locationInWindow, from: nil)
        if lastDragPoint == nil, hypot(current.x - mouseOrigin.x, current.y - mouseOrigin.y) < 7 { return }
        let last = lastDragPoint ?? mouseOrigin
        lastDragPoint = current
        onDrag?(current.x - last.x, current.y - last.y)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { mouseOrigin = nil; lastDragPoint = nil }
        if lastDragPoint != nil {
            onDragEnd?()
            return
        }
        guard let mouseOrigin, hypot(point.x - mouseOrigin.x, point.y - mouseOrigin.y) < 8 else { return }
        for hit in hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue]) {
            var node: SCNNode? = hit.node
            while let current = node {
                if let name = current.name, let key = RemoteKey(rawValue: name) {
                    onSelect?(key)
                    return
                }
                node = current.parent
            }
            // A solid unlabeled panel occludes the keys on the other face.
            if hit.node.name == "shell" { return }
        }
    }

    private func scheduleProjection() {
        guard !projectionPending else { return }
        projectionPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.projectionPending = false
            guard self.bounds.width > 1, self.bounds.height > 1 else { return }
            let points = self.anchors.mapValues { node in
                let point = self.projectPoint(node.worldPosition)
                return CGPoint(x: point.x, y: self.bounds.height - point.y)
            }
            guard points != self.lastProjection else { return }
            self.lastProjection = points
            self.onProjection?(points)
        }
    }

    private static let graphite = NSColor(srgbRed: 0.092, green: 0.103, blue: 0.131, alpha: 1)
    private static let keyGray = NSColor(srgbRed: 0.144, green: 0.157, blue: 0.191, alpha: 1)
    private static let metal = NSColor(srgbRed: 0.56, green: 0.58, blue: 0.64, alpha: 1)
    private static let selectedGlow = NSColor(srgbRed: 0.12, green: 0.18, blue: 0.46, alpha: 1)
    private static let lit = NSColor(srgbRed: 0.22, green: 0.42, blue: 0.80, alpha: 1)

    private func buildHardware() {
        bodyPanel(width: 2.18, height: 6.72, depth: 0.46, corner: 0.33, z: 0, color: Self.metal)
        bodyPanel(width: 2.12, height: 6.64, depth: 0.105, corner: 0.31, z: 0.22, color: Self.graphite)
        bodyPanel(width: 2.10, height: 6.61, depth: 0.09, corner: 0.30, z: -0.235, color: Self.metal)
        box(width: 0.045, height: 0.111, depth: 0.018, radius: 0.009,
            at: SCNVector3(0, 2.88, 0.28), color: .black)
        roundButton(.power, x: 0.68, y: 2.76, radius: 0.20, legendScale: 0.215)

        let ringY = 1.65
        directionRing(y: ringY, radius: 0.77)
        roundButton(.ok, x: 0, y: ringY, radius: 0.405, legendScale: nil)
        roundButton(.back, x: -0.45, y: 0.42, radius: 0.32, legendScale: 0.224)
        roundButton(.voice, x: 0.45, y: 0.42, radius: 0.32, legendScale: 0.245)
        roundButton(.home, x: 0.45, y: -0.42, radius: 0.32, legendScale: 0.23)
        roundButton(.menu, x: 0.45, y: -1.19, radius: 0.32, legendScale: 0.217)
        frontRocker(.mute, y: -0.43)
        frontRocker(.air, y: -1.15)
        sideControl(.volumeUp, y: 2.04, height: 0.45)
        sideControl(.volumeDown, y: 1.58, height: 0.45)
        sideControl(.charge, y: -2.02, height: 0.49)
        backKeyboard()
    }

    private func buildXiaomi() {
        let silver = NSColor(srgbRed: 0.62, green: 0.65, blue: 0.69, alpha: 1)
        let edge = NSColor(srgbRed: 0.36, green: 0.40, blue: 0.46, alpha: 1)
        bodyPanel(width: 1.76, height: 6.87, depth: 0.43, corner: 0.27, z: 0, color: edge)
        bodyPanel(width: 1.72, height: 6.82, depth: 0.10, corner: 0.25, z: 0.225, color: silver)
        bodyPanel(width: 1.70, height: 6.81, depth: 0.10, corner: 0.25, z: -0.225, color: silver)
        roundButton(.power, x: -0.49, y: 2.83, radius: 0.19, legendScale: 0.19)
        roundButton(.voice, x: 0.49, y: 2.83, radius: 0.19, legendScale: 0.19)
        box(width: 0.038, height: 0.075, depth: 0.013, radius: 0.009,
            at: SCNVector3(0, 2.84, 0.282), color: Self.graphite)
        directionRing(y: 1.72, radius: 0.64)
        roundButton(.ok, x: 0, y: 1.72, radius: 0.33, legendScale: nil)
        roundButton(.back, x: -0.43, y: 0.60, radius: 0.22, legendScale: 0.19)
        roundButton(.home, x: -0.43, y: -0.08, radius: 0.22, legendScale: 0.185)
        roundButton(.menu, x: -0.43, y: -0.76, radius: 0.22, legendScale: 0.18)
        roundButton(.tv, x: 0.43, y: -0.76, radius: 0.22, legendScale: 0.18)
        let rocker = roundedPlate(width: 0.43, height: 1.12, depth: 0.068, radius: 0.19)
        _ = add(rocker, at: SCNVector3(0.43, 0.26, 0.308), color: Self.graphite)
        for (key, y) in [(RemoteKey.volumeUp, 0.55), (.volumeDown, -0.025)] {
            let position = SCNVector3(0.43, y, 0.352)
            let cap = box(width: 0.33, height: 0.45, depth: 0.037, radius: 0.05,
                          at: SCNVector3(0.43, y, 0.320), color: Self.keyGray)
            register(key, on: cap, anchor: position)
            addLegend(key.icon, width: 0.18, at: position, key: key)
        }
        let port = box(width: 0.44, height: 0.032, depth: 0.17, radius: 0.014,
                       at: SCNVector3(0, -3.411, 0), color: Self.graphite)
        register(.charge, on: port, anchor: SCNVector3(0, -3.38, 0))
    }

    private func directionRing(y ringY: Double, radius: Double) {
        let sectors: [(RemoteKey, Double)] = [(.right, 0), (.up, 90), (.left, 180), (.down, 270)]
        for (key, angle) in sectors {
            let first = (angle - 44) * .pi / 180
            let last = (angle + 44) * .pi / 180
            let path = NSBezierPath()
            for i in 0...20 {
                let theta = first + (last - first) * Double(i) / 20
                let point = NSPoint(x: cos(theta) * radius, y: sin(theta) * radius)
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            for i in (0...20).reversed() {
                let theta = first + (last - first) * Double(i) / 20
                path.line(to: NSPoint(x: cos(theta) * radius * 0.547, y: sin(theta) * radius * 0.547))
            }
            path.close()
            let sector = SCNShape(path: path, extrusionDepth: 0.064)
            sector.chamferRadius = 0.016
            let node = add(sector, at: SCNVector3(0, ringY, 0.305), color: Self.graphite)
            let radians = angle * .pi / 180
            let target = SCNVector3(cos(radians) * radius * 0.78, ringY + sin(radians) * radius * 0.78, 0.353)
            register(key, on: node, anchor: target)
        }
    }

    private func bodyPanel(width: Double, height: Double, depth: Double, corner: Double, z: Double, color: NSColor) {
        let panel = roundedPlate(width: width, height: height, depth: depth, radius: corner)
        add(panel, at: SCNVector3(0, 0, z), color: color).name = "shell"
    }

    private func roundedPlate(width: Double, height: Double, depth: Double, radius: Double) -> SCNShape {
        let x = width / 2 - radius
        let y = height / 2 - radius
        let corners = [(x, y), (-x, y), (-x, -y), (x, -y)]
        let path = NSBezierPath()
        // Sample the corners so SceneKit doesn't flatten the small model-space curves.
        for (corner, center) in corners.enumerated() {
            for step in 0...12 {
                let theta = (Double(corner) + Double(step) / 12) * .pi / 2
                let point = NSPoint(x: center.0 + cos(theta) * radius, y: center.1 + sin(theta) * radius)
                if corner == 0 && step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
        }
        path.close()
        let panel = SCNShape(path: path, extrusionDepth: depth)
        panel.chamferRadius = min(depth / 3, 0.055)
        return panel
    }

    private func roundButton(_ key: RemoteKey, x: Double, y: Double, radius: Double, legendScale: Double?) {
        let cap = SCNCylinder(radius: radius, height: 0.072)
        cap.radialSegmentCount = 64
        let node = add(cap, at: SCNVector3(x, y, 0.313), color: Self.keyGray)
        node.eulerAngles.x = .pi / 2
        let target = SCNVector3(x, y, 0.36)
        register(key, on: node, anchor: target)
        if let legendScale {
            addLegend(key.icon, width: legendScale, at: target, key: key)
        }
    }

    private func frontRocker(_ key: RemoteKey, y: Double) {
        let geometry = roundedPlate(width: 0.61, height: 0.70, depth: 0.074, radius: 0.15)
        let button = add(geometry, at: SCNVector3(-0.45, y, 0.312), color: Self.keyGray)
        let target = SCNVector3(-0.45, y, 0.356)
        register(key, on: button, anchor: target)
        addLegend(key.icon, width: 0.228, at: target, key: key)
    }

    private func sideControl(_ key: RemoteKey, y: Double, height: Double) {
        let button = box(width: 0.25, height: height, depth: 0.077, radius: 0.035,
                         at: SCNVector3(1.08, y, -0.015), color: .black)
        button.eulerAngles.y = .pi / 2
        let target = SCNVector3(1.128, y, -0.015)
        register(key, on: button, anchor: target)
        if key != .charge {
            addLegend(key.icon, width: 0.15, at: target, key: key).eulerAngles.y = .pi / 2
        }
    }

    private func backKeyboard() {
        box(width: 1.79, height: 5.64, depth: 0.055, radius: 0.025,
            at: SCNVector3(0, 0, -0.286), color: NSColor(white: 0.36, alpha: 1)).name = "shell"
        let columns: [[String]] = [
            ["Esc", "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P", "Del"],
            ["Caps", "A", "S", "D", "F", "G", "H", "J", "K", "L", "Back"],
            ["Shift", "Z", "X", "C", "V", "B", "N", "M", "?", "↑", "Enter"],
            ["Ctrl", "Fn", "−", "＋", "Alt", "⎵", "Alt", "←", "↓", "→", ".com"]
        ]
        for (column, legends) in columns.enumerated() {
            let x = -0.65 + Double(column) * 0.435
            let step = 5.36 / Double(legends.count)
            for (row, legend) in legends.enumerated() {
                let y = 2.68 - step * (Double(row) + 0.5)
                let key: RemoteKey
                switch legend {
                case "Esc", "Del", "Back", "Enter": key = .keyboardEdit
                case "Caps", "Shift", "Ctrl", "Fn", "Alt": key = .keyboardModifiers
                case "←", "↑", "↓", "→": key = .keyboardArrows
                default: key = .typing
                }
                let node = box(width: 0.38, height: step - 0.035, depth: 0.065, radius: 0.028,
                               at: SCNVector3(x, y, -0.324), color: Self.graphite)
                node.name = key.rawValue
                keys[key, default: []].append(node)
                let size = legend.count > 1 ? 0.20 : 0.21
                let secondaryDigit = column == 0 && row >= 2 ? String((row - 1) % 10) : nil
                let glyph = addLegend(legend, width: size, at: SCNVector3(x, y, -0.36), key: key,
                                      literal: true, secondary: secondaryDigit)
                glyph.eulerAngles.y = .pi
                glyph.eulerAngles.z = -.pi / 2
            }
        }
        setAnchor(.typing, at: SCNVector3(0.40, 1.13, -0.37))
        setAnchor(.keyboardModifiers, at: SCNVector3(0.64, 2.31, -0.37))
        setAnchor(.keyboardArrows, at: SCNVector3(0.64, -1.67, -0.37))
        setAnchor(.keyboardEdit, at: SCNVector3(-0.20, -2.44, -0.37))
    }

    @discardableResult
    private func addLegend(
        _ symbol: String, width: Double, at position: SCNVector3, key: RemoteKey,
        literal: Bool = false, secondary: String? = nil
    ) -> SCNNode {
        let tile = SCNPlane(width: width, height: width)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        if literal {
            material.diffuse.contents = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { _ in
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: symbol.count > 1 ? 22 : 44, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
                let text = NSAttributedString(string: symbol, attributes: attrs)
                let size = text.size()
                let origin = NSPoint(x: (80 - size.width) / 2 - (secondary == nil ? 0 : 7),
                                     y: (80 - size.height) / 2)
                text.draw(at: origin)
                if let secondary {
                    let number = NSAttributedString(string: secondary, attributes: [
                        .font: NSFont.systemFont(ofSize: 20, weight: .medium),
                        .foregroundColor: NSColor(srgbRed: 0.62, green: 0.78, blue: 1, alpha: 1)
                    ])
                    number.draw(at: NSPoint(x: 59, y: 43))
                }
                return true
            }
        } else {
            material.diffuse.contents = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 72, weight: .semibold))?
                .withSymbolConfiguration(.init(paletteColors: [NSColor(white: 0.91, alpha: 1)]))
        }
        let node = SCNNode(geometry: tile)
        tile.firstMaterial = material
        node.name = key.rawValue
        #if T1_EXPORT_REMOTE
        exportLegends[ObjectIdentifier(node)] = ["text": symbol, "literal": literal, "secondary": secondary ?? ""]
        #endif
        node.position = position
        assembly.addChildNode(node)
        return node
    }

    @discardableResult
    private func box(width: Double, height: Double, depth: Double, radius: Double,
                     at position: SCNVector3, color: NSColor) -> SCNNode {
        let geometry = SCNBox(width: width, height: height, length: depth, chamferRadius: radius)
        geometry.chamferSegmentCount = 10
        return add(geometry, at: position, color: color)
    }

    private func add(_ geometry: SCNGeometry, at position: SCNVector3, color: NSColor) -> SCNNode {
        let material = SCNMaterial()
        material.lightingModel = .blinn
        material.diffuse.contents = color
        material.specular.contents = NSColor(white: 0.36, alpha: 1)
        material.shininess = 0.35
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.position = position
        assembly.addChildNode(node)
        return node
    }

    private func register(_ key: RemoteKey, on node: SCNNode, anchor: SCNVector3) {
        node.name = key.rawValue
        keys[key, default: []].append(node)
        setAnchor(key, at: anchor)
    }

    private func setAnchor(_ key: RemoteKey, at position: SCNVector3) {
        let node = SCNNode()
        node.position = position
        assembly.addChildNode(node)
        anchors[key] = node
    }

    private func installLight(in scene: SCNScene, type: SCNLight.LightType, color: NSColor,
                              intensity: CGFloat, pitch: Double = 0, yaw: Double = 0) {
        let node = SCNNode()
        let light = SCNLight()
        light.type = type
        light.color = color
        light.intensity = intensity
        node.light = light
        node.eulerAngles = SCNVector3(pitch, yaw, 0)
        scene.rootNode.addChildNode(node)
    }
}
