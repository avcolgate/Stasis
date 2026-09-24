import Foundation
import SwiftUI

@main
struct PowerDiagramTests {
    @MainActor
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        let size = CGSize(width: 272, height: 125)
        func layout(_ source: PowerSource, _ charging: Bool, _ battery: Double, _ adapter: Double, _ system: Double) -> PowerDiagramLayout {
            PowerDiagramLayout(
                diagram: .make(powerSource: source, isCharging: charging, batteryPower: battery, adapterPower: adapter, systemPower: system),
                size: size
            )
        }

        let split = layout(.acAdapter, true, 10, 40, 30)
        let charging = split.ribbons.first { $0.flow.kind == .charging }
        let grid = split.ribbons.first { $0.flow.kind == .grid }
        if let charging, let grid {
            check(abs(grid.thickness / charging.thickness - 3) < 0.01, "ribbon thickness is proportional to watts")
            check(charging.sinkBottom <= grid.sinkTop, "split ribbons do not cross")
        } else {
            check(false, "charging split has charging and grid ribbons")
        }

        let tiny = layout(.acAdapter, true, 1, 41, 40)
        let tinyFrames = Array(tiny.nodeFrames.values)
        check(tinyFrames.allSatisfy { $0.height >= 36 }, "tiny flows keep nodes tall enough for icons")
        check(tinyFrames.allSatisfy { $0.minY >= -0.5 && $0.maxY <= size.height + 0.5 }, "nodes stay inside the diagram")
        check(tiny.ribbons.allSatisfy { $0.thickness >= 3 }, "tiny flows remain visible")

        let holding = layout(.acAdapter, false, 0, 11, 11)
        check(holding.ribbons.count == 1 && holding.nodeFrames[.battery] != nil, "holding shows an idle battery without a flow")
        let holdingDiagram = PowerDiagram.make(powerSource: .acAdapter, isCharging: false, batteryPower: 0, adapterPower: 11, systemPower: 11)
        check(holdingDiagram.sinks.first { $0.id == .battery }?.watts == nil, "idle battery shows no wattage")
        let holdingShapes = PowerDiagramShapes(diagram: holdingDiagram, layout: PowerDiagramLayout(diagram: holdingDiagram, size: size, gap: 0))
        check(holdingShapes.idleNodes.count == 1, "idle battery is drawn as a neutral node")
        check(holdingShapes.tintedRegions.count == 3, "adapter, ribbon and Mac are tinted")

        let empty = layout(.acAdapter, false, 0, 0, 0)
        check(empty.ribbons.allSatisfy { $0.thickness.isFinite && $0.thickness > 0 }, "zero power still produces finite ribbons")

        let merge = layout(.both, false, -20, 36, 56)
        let mergeSources = merge.ribbons.map { $0.thickness }.reduce(0, +)
        if let mac = merge.nodeFrames[.mac] {
            check(abs(mac.height - max(36, mergeSources)) < 0.5, "sink node height matches its incoming ribbons")
        } else {
            check(false, "merge layout has a Mac node")
        }
        for ribbon in merge.ribbons {
            let start = merge.edgePoint(ribbon, progress: 0, across: 0)
            let end = merge.edgePoint(ribbon, progress: 1, across: 1)
            check(abs(start.y - ribbon.sourceTop) < 0.01 && abs(end.y - ribbon.sinkBottom) < 0.01, "particle path matches ribbon edges")
        }

        let key = PowerFlowKey(PowerFlow(from: .adapter, to: .mac, watts: 10, kind: .grid))
        let animator = FlowAnimator()
        let reference = 800_000_000.0
        _ = animator.advance(to: reference, speeds: [key: 0.2])
        let beforeChange = animator.advance(to: reference + 1.0 / 60, speeds: [key: 0.2])[key] ?? -1
        let afterChange = animator.advance(to: reference + 2.0 / 60, speeds: [key: 0.35])[key] ?? -1
        check(abs(afterChange - beforeChange - 0.35 / 60) < 1e-6, "changing power changes speed without a phase jump")
        let afterPause = animator.advance(to: reference + 30, speeds: [key: 0.35])[key] ?? -1
        check(abs(afterPause - afterChange - 0.035) < 1e-6, "a long pause advances by at most one clamped step")

        check(FlowSheen.intensity(progress: 0, phase: 0) == 0 && FlowSheen.intensity(progress: 1, phase: 0.5) == 0, "the sheen fades out at both ends of a ribbon")
        check(FlowSheen.intensity(progress: 0.5, phase: 0.5) > 0.99, "the sheen peaks at its center")
        check(abs(FlowSheen.intensity(progress: 0.4, phase: 0.999_999) - FlowSheen.intensity(progress: 0.4, phase: 0)) < 1e-4, "the sheen has no seam when the phase wraps")
        let sheenLayout = layout(.acAdapter, true, 10, 40, 30)
        let stops = FlowSheen.gradient(layout: sheenLayout, phase: 0.3, peakOpacity: 0.6).stops
        check(abs(stops.first?.location ?? -1) < 1e-9 && abs((stops.last?.location ?? -1) - 1) < 1e-9, "sheen gradient spans the whole ribbon")
        check(zip(stops, stops.dropFirst()).allSatisfy { $0.location <= $1.location }, "sheen gradient stops are ordered")

        check(TemperatureLevel(temperature: 31, limit: 40) == .normal, "cool battery is normal")
        check(TemperatureLevel(temperature: 36, limit: 40) == .warm, "battery near the heat limit is warm")
        check(TemperatureLevel(temperature: 41, limit: 40) == .hot, "battery above the heat limit is hot")
        check(TemperatureLevel(temperature: 0, limit: 40) == .normal, "unknown temperature is not highlighted")

        exit(failures == 0 ? 0 : 1)
    }
}
