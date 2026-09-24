import SwiftUI

enum PowerNodeID: Hashable {
    case adapter, battery, mac
}

enum PowerFlowKind {
    case grid, charging, discharging

    var color: Color {
        switch self {
        case .grid: .blue
        case .charging: .green
        case .discharging: .orange
        }
    }

}

struct PowerNode: Equatable {
    let id: PowerNodeID
    let icon: String
    let watts: Double?
}

struct PowerFlow: Equatable {
    let from: PowerNodeID
    let to: PowerNodeID
    let watts: Double
    let kind: PowerFlowKind
}

struct PowerDiagram: Equatable {
    let sources: [PowerNode]
    let sinks: [PowerNode]
    let flows: [PowerFlow]

    static func make(
        powerSource: PowerSource,
        isCharging: Bool,
        batteryPower: Double,
        adapterPower: Double,
        systemPower: Double
    ) -> PowerDiagram {
        switch powerSource {
        case .battery:
            return PowerDiagram(
                sources: [PowerNode(id: .battery, icon: "battery.100", watts: nil)],
                sinks: [PowerNode(id: .mac, icon: "laptopcomputer", watts: nil)],
                flows: [PowerFlow(from: .battery, to: .mac, watts: abs(systemPower), kind: .discharging)]
            )
        case .both:
            return PowerDiagram(
                sources: [
                    PowerNode(id: .battery, icon: "battery.100", watts: nil),
                    PowerNode(id: .adapter, icon: "powerplug.fill", watts: nil),
                ],
                sinks: [PowerNode(id: .mac, icon: "laptopcomputer", watts: systemPower)],
                flows: [
                    PowerFlow(from: .battery, to: .mac, watts: abs(batteryPower), kind: .discharging),
                    PowerFlow(from: .adapter, to: .mac, watts: adapterPower, kind: .grid),
                ]
            )
        case .acAdapter where batteryPower > 0:
            return PowerDiagram(
                sources: [PowerNode(id: .adapter, icon: "powerplug.fill", watts: adapterPower)],
                sinks: [
                    PowerNode(id: .battery, icon: isCharging ? "battery.100.bolt" : "battery.100", watts: nil),
                    PowerNode(id: .mac, icon: "laptopcomputer", watts: nil),
                ],
                flows: [
                    PowerFlow(from: .adapter, to: .battery, watts: batteryPower, kind: .charging),
                    PowerFlow(from: .adapter, to: .mac, watts: systemPower, kind: .grid),
                ]
            )
        case .acAdapter:
            // Holding at the charge limit: the battery is idle, but showing it makes that explicit.
            return PowerDiagram(
                sources: [PowerNode(id: .adapter, icon: "powerplug.fill", watts: nil)],
                sinks: [
                    PowerNode(id: .battery, icon: "battery.100", watts: nil),
                    PowerNode(id: .mac, icon: "laptopcomputer", watts: nil),
                ],
                flows: [PowerFlow(from: .adapter, to: .mac, watts: adapterPower, kind: .grid)]
            )
        }
    }
}

struct PowerDiagramLayout {
    struct Ribbon {
        let flow: PowerFlow
        let sourceTop: CGFloat
        let sourceBottom: CGFloat
        let sinkTop: CGFloat
        let sinkBottom: CGFloat

        var thickness: CGFloat { sourceBottom - sourceTop }
    }

    let nodeFrames: [PowerNodeID: CGRect]
    let ribbons: [Ribbon]
    let flowStartX: CGFloat
    let flowEndX: CGFloat

    init(
        diagram: PowerDiagram,
        size: CGSize,
        nodeWidth: CGFloat = 60,
        gap: CGFloat = 5,
        nodeSpacing: CGFloat = 20,
        minimumNodeHeight: CGFloat = 36,
        minimumRibbonThickness: CGFloat = 3
    ) {
        flowStartX = nodeWidth + gap
        flowEndX = size.width - nodeWidth - gap

        // With no measurable power yet every flow gets equal weight, so the shape stays stable.
        let hasPower = diagram.flows.contains { $0.watts > 0 }
        func weight(_ flow: PowerFlow) -> CGFloat {
            hasPower ? CGFloat(max(flow.watts, 0)) : 1
        }
        func total(_ node: PowerNode, isSource: Bool) -> CGFloat {
            diagram.flows
                .filter { (isSource ? $0.from : $0.to) == node.id }
                .reduce(0) { $0 + weight($1) }
        }

        // Nodes too small to hold their icon are clamped to the minimum height and excluded
        // from the proportional share, so the scale is solved per side and the tighter one wins.
        func scale(for nodes: [PowerNode], isSource: Bool) -> CGFloat {
            let totals = nodes.map { total($0, isSource: isSource) }
            let available = size.height - nodeSpacing * CGFloat(max(nodes.count - 1, 0))
            var clamped = Set<Int>()
            var scale = CGFloat.greatestFiniteMagnitude
            for _ in 0...nodes.count {
                let flexibleTotal = totals.indices.filter { !clamped.contains($0) }.reduce(0) { $0 + totals[$1] }
                guard flexibleTotal > 0 else { return scale }
                scale = (available - CGFloat(clamped.count) * minimumNodeHeight) / flexibleTotal
                let newlyClamped = totals.indices.filter {
                    !clamped.contains($0) && totals[$0] * scale < minimumNodeHeight
                }
                if newlyClamped.isEmpty { break }
                clamped.formUnion(newlyClamped)
            }
            return max(scale, 0)
        }

        let ribbonScale = min(
            scale(for: diagram.sources, isSource: true),
            scale(for: diagram.sinks, isSource: false)
        )
        func thickness(_ flow: PowerFlow) -> CGFloat {
            max(weight(flow) * ribbonScale, minimumRibbonThickness)
        }

        var frames: [PowerNodeID: CGRect] = [:]
        func placeColumn(_ nodes: [PowerNode], x: CGFloat, isSource: Bool) {
            let heights = nodes.map { node in
                max(
                    minimumNodeHeight,
                    diagram.flows.filter { (isSource ? $0.from : $0.to) == node.id }.reduce(0) { $0 + thickness($1) }
                )
            }
            let used = heights.reduce(0, +) + nodeSpacing * CGFloat(max(nodes.count - 1, 0))
            var y = max((size.height - used) / 2, 0)
            for (node, height) in zip(nodes, heights) {
                frames[node.id] = CGRect(x: x, y: y, width: nodeWidth, height: height)
                y += height + nodeSpacing
            }
        }
        placeColumn(diagram.sources, x: 0, isSource: true)
        placeColumn(diagram.sinks, x: size.width - nodeWidth, isSource: false)

        // Stack each node's ribbons in the order of their far ends so ribbons never cross.
        let sinkOrder = Dictionary(uniqueKeysWithValues: diagram.sinks.enumerated().map { ($1.id, $0) })
        let sourceOrder = Dictionary(uniqueKeysWithValues: diagram.sources.enumerated().map { ($1.id, $0) })
        func offsets(for nodeID: PowerNodeID, isSource: Bool) -> [Int: (top: CGFloat, bottom: CGFloat)] {
            let attached = diagram.flows.indices
                .filter { (isSource ? diagram.flows[$0].from : diagram.flows[$0].to) == nodeID }
                .sorted {
                    let lhs = diagram.flows[$0], rhs = diagram.flows[$1]
                    return isSource
                        ? (sinkOrder[lhs.to] ?? 0) < (sinkOrder[rhs.to] ?? 0)
                        : (sourceOrder[lhs.from] ?? 0) < (sourceOrder[rhs.from] ?? 0)
                }
            guard let frame = frames[nodeID] else { return [:] }
            let stackHeight = attached.reduce(0) { $0 + thickness(diagram.flows[$1]) }
            var y = frame.midY - stackHeight / 2
            var result: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
            for index in attached {
                let height = thickness(diagram.flows[index])
                result[index] = (y, y + height)
                y += height
            }
            return result
        }

        var sourceEnds: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
        var sinkEnds: [Int: (top: CGFloat, bottom: CGFloat)] = [:]
        for node in diagram.sources { sourceEnds.merge(offsets(for: node.id, isSource: true)) { $1 } }
        for node in diagram.sinks { sinkEnds.merge(offsets(for: node.id, isSource: false)) { $1 } }

        nodeFrames = frames
        ribbons = diagram.flows.indices.compactMap { index in
            guard let source = sourceEnds[index], let sink = sinkEnds[index] else { return nil }
            return Ribbon(
                flow: diagram.flows[index],
                sourceTop: source.top,
                sourceBottom: source.bottom,
                sinkTop: sink.top,
                sinkBottom: sink.bottom
            )
        }
    }

    func edgePoint(_ ribbon: Ribbon, progress: CGFloat, across: CGFloat) -> CGPoint {
        let top = curvePoint(from: ribbon.sourceTop, to: ribbon.sinkTop, progress: progress)
        let bottom = curvePoint(from: ribbon.sourceBottom, to: ribbon.sinkBottom, progress: progress)
        return CGPoint(x: top.x + (bottom.x - top.x) * across, y: top.y + (bottom.y - top.y) * across)
    }

    func path(for ribbon: Ribbon) -> Path {
        let controlX = (flowStartX + flowEndX) / 2
        return Path { path in
            path.move(to: CGPoint(x: flowStartX, y: ribbon.sourceTop))
            path.addCurve(
                to: CGPoint(x: flowEndX, y: ribbon.sinkTop),
                control1: CGPoint(x: controlX, y: ribbon.sourceTop),
                control2: CGPoint(x: controlX, y: ribbon.sinkTop)
            )
            path.addLine(to: CGPoint(x: flowEndX, y: ribbon.sinkBottom))
            path.addCurve(
                to: CGPoint(x: flowStartX, y: ribbon.sourceBottom),
                control1: CGPoint(x: controlX, y: ribbon.sinkBottom),
                control2: CGPoint(x: controlX, y: ribbon.sourceBottom)
            )
            path.closeSubpath()
        }
    }

    func curveX(progress: CGFloat) -> CGFloat {
        curvePoint(from: 0, to: 0, progress: progress).x
    }

    private func curvePoint(from startY: CGFloat, to endY: CGFloat, progress t: CGFloat) -> CGPoint {
        let controlX = (flowStartX + flowEndX) / 2
        let inverse = 1 - t
        let a = inverse * inverse * inverse
        let b = 3 * inverse * inverse * t
        let c = 3 * inverse * t * t
        let d = t * t * t
        return CGPoint(
            x: a * flowStartX + b * controlX + c * controlX + d * flowEndX,
            y: a * startY + b * startY + c * endY + d * endY
        )
    }
}

struct PowerFlowKey: Hashable {
    let from: PowerNodeID
    let to: PowerNodeID

    init(_ flow: PowerFlow) {
        from = flow.from
        to = flow.to
    }
}

/// Integrates each flow's phase frame by frame. Deriving the phase from absolute time
/// times speed would make every particle jump whenever the measured power changes.
final class FlowAnimator {
    private static let maximumFrameStep: TimeInterval = 0.1

    private var lastTime: TimeInterval?
    private var phases: [PowerFlowKey: Double] = [:]

    func advance(to time: TimeInterval, speeds: [PowerFlowKey: Double]) -> [PowerFlowKey: Double] {
        // Clamping the step keeps particles from leaping after the menu was closed.
        let step = lastTime.map { min(max(time - $0, 0), Self.maximumFrameStep) } ?? 0
        lastTime = time
        var advanced: [PowerFlowKey: Double] = [:]
        for (key, speed) in speeds {
            let phase = (phases[key] ?? 0) + step * speed
            advanced[key] = phase - phase.rounded(.down)
        }
        phases = advanced
        return advanced
    }
}

/// Filled regions of the diagram: tinted nodes joined to their ribbons, plus idle nodes.
struct PowerDiagramShapes {
    let tintedRegions: [(path: Path, color: Color)]
    let silhouette: Path
    let idleNodes: [Path]

    static let cornerRadius: CGFloat = 16
    // A node taller than its ribbons would meet a thin ribbon with a flat, cut-off edge.
    private static let minimumSlackForInnerRounding: CGFloat = 4

    init(diagram: PowerDiagram, layout: PowerDiagramLayout) {
        var regions: [(path: Path, color: Color)] = []
        var silhouette = Path()
        var idle: [Path] = []

        for node in diagram.sources + diagram.sinks {
            guard let frame = layout.nodeFrames[node.id] else { continue }
            let isSource = diagram.sources.contains { $0.id == node.id }
            let attached = layout.ribbons.filter { (isSource ? $0.flow.from : $0.flow.to) == node.id }
            let ribbonHeight = attached.reduce(0) { $0 + $1.thickness }
            let slack = frame.height - ribbonHeight
            let innerRadius = attached.isEmpty
                ? Self.cornerRadius
                : (slack > Self.minimumSlackForInnerRounding ? min(Self.cornerRadius, slack / 2) : 0)
            let shape = Self.nodeShape(frame: frame, isSource: isSource, innerRadius: innerRadius)
            guard !attached.isEmpty else {
                idle.append(shape)
                continue
            }
            silhouette = silhouette.union(shape)
            // Each attached ribbon's color fills a share of the node, stretched to the node's height.
            var y = frame.minY
            for ribbon in attached {
                let height = frame.height * ribbon.thickness / max(ribbonHeight, 1)
                regions.append((Path(CGRect(x: frame.minX, y: y, width: frame.width, height: height)), ribbon.flow.kind.color))
                y += height
            }
        }
        for ribbon in layout.ribbons {
            let path = layout.path(for: ribbon)
            silhouette = silhouette.union(path)
            regions.append((path, ribbon.flow.kind.color))
        }

        tintedRegions = regions
        self.silhouette = silhouette
        idleNodes = idle
    }

    static func nodeShape(frame: CGRect, isSource: Bool, innerRadius: CGFloat) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: isSource ? cornerRadius : innerRadius,
            bottomLeadingRadius: isSource ? cornerRadius : innerRadius,
            bottomTrailingRadius: isSource ? innerRadius : cornerRadius,
            topTrailingRadius: isSource ? innerRadius : cornerRadius,
            style: .continuous
        )
        .path(in: frame)
    }
}

struct PowerSankeyView: View {
    let powerSource: PowerSource
    let isCharging: Bool
    let batteryPower: Double
    let adapterPower: Double
    let systemPower: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var animator = FlowAnimator()

    private enum Layout {
        static let viewHeight: CGFloat = 125
        static let minimumAnimatedWatts = 0.05
        static let colorBlendRadius: CGFloat = 9
        static let tintOpacityAtSource = 0.32
        static let tintOpacityAtSink = 0.2
        static let idleNodeOpacity = 0.07
        // Lightening an already light surface shows less, so the sheen is stronger in light mode.
        static let sheenOpacityLight = 0.55
        static let sheenOpacityDark = 0.32
    }

    private var diagram: PowerDiagram {
        PowerDiagram.make(
            powerSource: powerSource,
            isCharging: isCharging,
            batteryPower: batteryPower,
            adapterPower: adapterPower,
            systemPower: systemPower
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let diagram = diagram
            let layout = PowerDiagramLayout(diagram: diagram, size: geometry.size, gap: 0)
            let shapes = PowerDiagramShapes(diagram: diagram, layout: layout)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawTint(context: context, size: size, shapes: shapes)
                }

                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                    Canvas { context, _ in
                        drawSheen(context: context, layout: layout, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }

                ForEach(layout.ribbons.indices, id: \.self) { index in
                    let ribbon = layout.ribbons[index]
                    PowerLabel(power: ribbon.flow.watts)
                        .position(layout.edgePoint(ribbon, progress: 0.5, across: 0.5))
                }

                ForEach(diagram.sources + diagram.sinks, id: \.id) { node in
                    if let frame = layout.nodeFrames[node.id] {
                        NodeLabel(icon: node.icon, value: node.watts)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
        }
        .frame(height: Layout.viewHeight)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Colors are painted opaque and blurred so neighbouring flows blend softly, then clipped to
    /// the sharp silhouette and faded as one layer, so overlaps never darken and no seams appear.
    private func drawTint(context: GraphicsContext, size: CGSize, shapes: PowerDiagramShapes) {
        for idle in shapes.idleNodes {
            context.fill(idle, with: .color(.primary.opacity(Layout.idleNodeOpacity)))
        }
        context.drawLayer { tinted in
            tinted.clip(to: shapes.silhouette)
            tinted.drawLayer { blended in
                blended.addFilter(.blur(radius: Layout.colorBlendRadius))
                for region in shapes.tintedRegions {
                    blended.fill(region.path, with: .color(region.color))
                    // Bleeding each color outward keeps the blur from thinning it at the outline.
                    blended.stroke(region.path, with: .color(region.color), lineWidth: Layout.colorBlendRadius * 2)
                }
            }
            var fade = tinted
            fade.blendMode = .destinationIn
            fade.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [.black.opacity(Layout.tintOpacityAtSource), .black.opacity(Layout.tintOpacityAtSink)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                )
            )
        }
    }

    private func drawSheen(context: GraphicsContext, layout: PowerDiagramLayout, time: TimeInterval) {
        let length = Double(max(layout.flowEndX - layout.flowStartX, 1))
        var speeds: [PowerFlowKey: Double] = [:]
        for ribbon in layout.ribbons where ribbon.flow.watts >= Layout.minimumAnimatedWatts {
            speeds[PowerFlowKey(ribbon.flow)] = FlowSheen.pixelsPerSecond(watts: ribbon.flow.watts) / length
        }
        let phases = animator.advance(to: time, speeds: speeds)
        guard !reduceMotion else { return }
        let peakOpacity = colorScheme == .dark ? Layout.sheenOpacityDark : Layout.sheenOpacityLight
        var sheen = context
        sheen.blendMode = .plusLighter
        for ribbon in layout.ribbons {
            guard let phase = phases[PowerFlowKey(ribbon.flow)] else { continue }
            sheen.fill(
                layout.path(for: ribbon),
                with: .linearGradient(
                    FlowSheen.gradient(layout: layout, phase: phase, peakOpacity: peakOpacity),
                    startPoint: CGPoint(x: layout.flowStartX, y: 0),
                    endPoint: CGPoint(x: layout.flowEndX, y: 0)
                )
            )
        }
    }
}

/// A soft sheen of light travelling through a ribbon in the direction of energy flow.
///
/// Both ribbon edges share the same x(t) because their Bézier control points share an x,
/// so every vertical line crosses the ribbon at a single progress value. One horizontal
/// gradient whose stops follow the wave profile therefore paints the whole ribbon without seams.
enum FlowSheen {
    static let bandCount = 1
    static let bandWidth = 0.16
    static let sampleCount = 48
    static let edgeFade = 0.15

    static func pixelsPerSecond(watts: Double) -> Double {
        min(120, 22 + 2.5 * watts)
    }

    static func intensity(progress: Double, phase: Double) -> Double {
        var value = 0.0
        for band in 0..<bandCount {
            let center = Double(band) / Double(bandCount) + phase
            var distance = abs(progress - (center - center.rounded(.down)))
            distance = min(distance, 1 - distance)
            value = max(value, exp(-(distance * distance) / (2 * bandWidth * bandWidth)))
        }
        // The sheen emerges from the source and fades into the sink instead of popping at the edges.
        let envelope = smoothstep(min(progress, 1 - progress) / edgeFade)
        return value * envelope
    }

    static func gradient(layout: PowerDiagramLayout, phase: Double, peakOpacity: Double) -> Gradient {
        let width = max(layout.flowEndX - layout.flowStartX, 1)
        let stops = (0...sampleCount).map { sample -> Gradient.Stop in
            let progress = Double(sample) / Double(sampleCount)
            let x = layout.curveX(progress: progress)
            return Gradient.Stop(
                color: .white.opacity(peakOpacity * intensity(progress: progress, phase: phase)),
                location: (x - layout.flowStartX) / width
            )
        }
        return Gradient(stops: stops)
    }

    private static func smoothstep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

struct PowerLabel: View {
    let power: Double
    var body: some View {
        Text(String(format: "%.0f W", abs(power)))
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

struct NodeLabel: View {
    let icon: String
    let value: Double?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            if let value {
                Text(String(format: "%.0f W", value))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    let items: [(PowerSource, Bool, Double, Double, Double)] = [
        (.both, false, -20.16, 36.0, 56.16),
        (.acAdapter, true, 20.0, 30.0, 10.0),
        (.battery, false, -18.63, 0.0, 18.63),
        (.acAdapter, false, 0.0, 25.0, 25.0),
        (.acAdapter, true, 2, 42, 40),
    ]
    LazyVGrid(
        columns: [
            GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()),
        ],
        spacing: 16
    ) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            PowerSankeyView(
                powerSource: item.0,
                isCharging: item.1,
                batteryPower: item.2,
                adapterPower: item.3,
                systemPower: item.4
            )
        }
    }
    .padding(12)
    .frame(width: 900)
}
