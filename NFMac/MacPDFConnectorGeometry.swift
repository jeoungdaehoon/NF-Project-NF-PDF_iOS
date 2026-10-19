import AppKit

/// Object-aware geometry shared by display, hit testing, drag preview and export.
/// PDF coordinates are y-up. Stored anchors/offsets are not rewritten by drawing.
struct MacPDFConnectorGeometry {
    let points: [CGPoint]
    let sourceAnchor: MacPDFPoint
    let targetAnchor: MacPDFPoint
    let protectedObjects: [MacPDFObject]
    let clearance: CGFloat
    let curved: Bool
    let controlPoint: CGPoint

    var tip: CGPoint { points.last! }
    var previous: CGPoint { points[points.count - 2] }
    func path(endInset: CGFloat = 0) -> CGPath {
        var vertices = points
        let distance = hypot(tip.x - previous.x, tip.y - previous.y)
        let inset = min(endInset, distance * 0.3)
        if distance > 0.001 { vertices[vertices.count - 1] = CGPoint(x: tip.x - (tip.x - previous.x) * inset / distance, y: tip.y - (tip.y - previous.y) * inset / distance) }
        let path = CGMutablePath(); path.move(to: vertices[0])
        for index in 1..<vertices.count {
            let corner = vertices[index]
            guard curved, index < vertices.count - 1 else { path.addLine(to: corner); continue }
            let before = vertices[index - 1], after = vertices[index + 1]
            let incoming = hypot(corner.x - before.x, corner.y - before.y), outgoing = hypot(after.x - corner.x, after.y - corner.y)
            let radius = min(4, clearance * 0.5, incoming * 0.25, outgoing * 0.25)
            guard radius > 0.001 else { path.addLine(to: corner); continue }
            path.addLine(to: CGPoint(x: corner.x + (before.x - corner.x) * radius / incoming, y: corner.y + (before.y - corner.y) * radius / incoming))
            path.addQuadCurve(to: CGPoint(x: corner.x + (after.x - corner.x) * radius / outgoing, y: corner.y + (after.y - corner.y) * radius / outgoing), control: corner)
        }
        return path
    }

    static func make(_ connector: MacPDFObject, objects: [MacPDFObject]) -> Self? {
        guard let source = objects.first(where: { $0.id == connector.sourceID && $0.page == connector.page }),
              let target = objects.first(where: { $0.id == connector.targetID && $0.page == connector.page }),
              let (a, b) = MacPDFObjectRenderer.endpoints(connector, objects: objects) else { return nil }
        let control = connector.connectorOffset.map { CGPoint(x: (a.x + b.x) / 2 + CGFloat($0.x), y: (a.y + b.y) / 2 + CGFloat($0.y)) }
        var targetAnchor = connector.targetAnchor
        // A bent connector approaching from below/above must land on that face,
        // not run vertically along a previously stored left/right box border.
        if connector.style.connectorRoute == "elbow", let control {
            let p = local(control, object: target), r = target.bounds
            if p.y < r.minY { targetAnchor = MacPDFPoint(CGPoint(x: 0.5, y: 0)) }
            else if p.y > r.maxY { targetAnchor = MacPDFPoint(CGPoint(x: 0.5, y: 1)) }
            else if p.x > r.maxX { targetAnchor = MacPDFPoint(CGPoint(x: 1, y: 0.5)) }
            else if p.x < r.minX { targetAnchor = MacPDFPoint(CGPoint(x: 0, y: 0.5)) }
        }
        let anchors = [connector.sourceAnchor] + (connector.style.connectorRoute == "elbow" ? MacPDFEditingView.connectionAnchors.map { MacPDFPoint($0) }.filter { $0 != connector.sourceAnchor } : [])
        return anchors.compactMap { candidate(connector, source: source, target: target, sourceAnchor: $0, targetAnchor: targetAnchor, control: control, midpoint: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)) }
            .min { lhs, rhs in
                // Keep the user's original face when the visual result ties;
                // switch only when another face removes bends or a long detour.
                let left = lhs.cost(width: connector.style.width) + (lhs.sourceAnchor == connector.sourceAnchor ? 0 : 4)
                let right = rhs.cost(width: connector.style.width) + (rhs.sourceAnchor == connector.sourceAnchor ? 0 : 4)
                return left < right
            }
    }

    private static func candidate(_ connector: MacPDFObject, source: MacPDFObject, target: MacPDFObject, sourceAnchor: MacPDFPoint, targetAnchor: MacPDFPoint, control: CGPoint?, midpoint: CGPoint) -> Self? {
        let width = CGFloat(max(0.5, connector.style.width)), clearance = max(2, width * 0.5 + 1)
        let protected = [source, target]
        let obstacles = protected.map { bounds($0).insetBy(dx: -(clearance + max(0, $0.style.width) * 0.5 + width * 0.5 + 2), dy: -(clearance + max(0, $0.style.width) * 0.5 + width * 0.5 + 2)) }
        func port(_ object: MacPDFObject, _ anchor: MacPDFPoint, obstacle: CGRect) -> (CGPoint, CGPoint) {
            let edge = MacPDFObjectRenderer.anchor(object, anchor), normal = normal(object, anchor)
            let gap = clearance + max(0, object.style.width) * 0.5
            let tip = CGPoint(x: edge.x + normal.dx * gap, y: edge.y + normal.dy * gap)
            var distance = max(14, width * 6 + 2)
            // Rotated objects' cardinal ports may lie inside their world AABB.
            // Extend the normal stub beyond that AABB before Manhattan routing.
            if abs(normal.dx) > 0.001 { distance = max(distance, ((normal.dx > 0 ? obstacle.maxX : obstacle.minX) - tip.x) / normal.dx + 1) }
            if abs(normal.dy) > 0.001 { distance = max(distance, ((normal.dy > 0 ? obstacle.maxY : obstacle.minY) - tip.y) / normal.dy + 1) }
            return (tip, CGPoint(x: tip.x + normal.dx * distance, y: tip.y + normal.dy * distance))
        }
        let (start, exit) = port(source, sourceAnchor, obstacle: obstacles[0])
        let (end, entry) = port(target, targetAnchor, obstacle: obstacles[1])
        let departure = CGVector(dx: exit.x - start.x, dy: exit.y - start.y)
        let arrival = CGVector(dx: end.x - entry.x, dy: end.y - entry.y)
        var middle: [CGPoint]
        var displayedGuide = control ?? midpoint
        if let control, !obstacles.contains(where: { $0.insetBy(dx: 0.0001, dy: 0.0001).contains(control) }) {
            // A grip inside a box is a routing hint, not a mandatory waypoint:
            // forcing it around the perimeter used to wrap the entire box.
            var guide = control
            if connector.style.connectorRoute == "elbow" {
                let tolerance = max(4, min(12, width * 2))
                let targetNormal = normal(target, targetAnchor), sourceNormal = normal(source, sourceAnchor)
                if abs(targetNormal.dy) < 0.001, abs(guide.y - end.y) <= tolerance { guide.y = end.y }
                else if abs(targetNormal.dx) < 0.001, abs(guide.x - end.x) <= tolerance { guide.x = end.x }
                if abs(sourceNormal.dy) < 0.001, abs(guide.y - start.y) <= tolerance { guide.y = start.y }
                else if abs(sourceNormal.dx) < 0.001, abs(guide.x - start.x) <= tolerance { guide.x = start.x }
                // Never snap a close parallel segment through a protected box.
                if obstacles.contains(where: { $0.insetBy(dx: 0.0001, dy: 0.0001).contains(guide) }) { guide = control }
            }
            displayedGuide = guide
            let first = route(from: exit, to: guide, obstacles: obstacles, departure: departure)
            let prior = first.count > 1 ? first[first.count - 2] : start
            middle = first + route(from: guide, to: entry, obstacles: obstacles, departure: CGVector(dx: guide.x - prior.x, dy: guide.y - prior.y), arrival: arrival).dropFirst()
        } else if connector.style.connectorRoute == "straight",
                  (entry.x - exit.x) * departure.dx + (entry.y - exit.y) * departure.dy >= 0,
                  (entry.x - exit.x) * arrival.dx + (entry.y - exit.y) * arrival.dy >= 0,
                  !obstacles.contains(where: { crosses(exit, entry, rect: $0) }) {
            middle = [exit, entry]
        } else { middle = route(from: exit, to: entry, obstacles: obstacles, departure: departure, arrival: arrival) }
        let points = simplified([start] + middle + [end])
        guard points.count > 1 else { return nil }
        return Self(points: points, sourceAnchor: sourceAnchor, targetAnchor: targetAnchor, protectedObjects: protected, clearance: clearance, curved: connector.style.connectorRoute == "curve", controlPoint: nearestPoint(to: displayedGuide, on: points))
    }

    var bendCount: Int {
        guard points.count > 2 else { return 0 }
        return (1..<points.count - 1).filter { index in
            let a = points[index - 1], b = points[index], c = points[index + 1]
            return abs((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)) > 0.001
        }.count
    }
    private func cost(width: CGFloat) -> CGFloat {
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        return length + CGFloat(bendCount) * max(20, width * 8)
    }
    private static func simplified(_ vertices: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in vertices {
            if let last = result.last, hypot(point.x - last.x, point.y - last.y) < 0.001 { continue }
            while result.count > 1 {
                let a = result[result.count - 2], b = result[result.count - 1]
                let cross = (b.x - a.x) * (point.y - b.y) - (b.y - a.y) * (point.x - b.x)
                let dot = (b.x - a.x) * (point.x - b.x) + (b.y - a.y) * (point.y - b.y)
                guard abs(cross) < 0.001, dot >= 0 else { break }
                result.removeLast()
            }
            result.append(point)
        }
        return result
    }
    private static func nearestPoint(to point: CGPoint, on vertices: [CGPoint]) -> CGPoint {
        zip(vertices, vertices.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y, distance = dx * dx + dy * dy
            let t = distance > 0.001 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / distance)) : 0
            return CGPoint(x: a.x + dx * t, y: a.y + dy * t)
        }.min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) } ?? point
    }

    static func local(_ p: CGPoint, object: MacPDFObject) -> CGPoint {
        let dx = p.x - object.bounds.midX, dy = p.y - object.bounds.midY
        return CGPoint(x: object.bounds.midX + dx * cos(-object.rotation) - dy * sin(-object.rotation), y: object.bounds.midY + dx * sin(-object.rotation) + dy * cos(-object.rotation))
    }
    static func normal(_ object: MacPDFObject, _ anchor: MacPDFPoint) -> CGVector {
        let x = anchor.x - 0.5, y = anchor.y - 0.5
        let dx: CGFloat = abs(x) > abs(y) ? (x < 0 ? -1 : 1) : 0
        let dy: CGFloat = dx == 0 ? (y < 0 ? -1 : 1) : 0
        return CGVector(dx: dx * cos(object.rotation) - dy * sin(object.rotation), dy: dx * sin(object.rotation) + dy * cos(object.rotation))
    }
    static func bounds(_ object: MacPDFObject) -> CGRect {
        MacPDFObjectRenderer.corners(object).reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }
    static func crosses(_ a: CGPoint, _ b: CGPoint, rect: CGRect) -> Bool {
        let r = rect.insetBy(dx: 0.0001, dy: 0.0001)
        var lower: CGFloat = 0, upper: CGFloat = 1
        for (origin, delta, minimum, maximum) in [(a.x, b.x - a.x, r.minX, r.maxX), (a.y, b.y - a.y, r.minY, r.maxY)] {
            if abs(delta) < 0.000001 { if origin < minimum || origin > maximum { return false } }
            else {
                let one = (minimum - origin) / delta, two = (maximum - origin) / delta
                lower = max(lower, min(one, two)); upper = min(upper, max(one, two))
                if upper < lower { return false }
            }
        }
        return upper - lower > 0.000001
    }
    // Small rectilinear visibility grid around the two connected boxes; unlike
    // fixed midpoint elbows, every segment is checked against protected bounds.
    private static func route(from start: CGPoint, to end: CGPoint, obstacles: [CGRect], departure: CGVector? = nil, arrival: CGVector? = nil) -> [CGPoint] {
        // Prefer a simple L over equal-length staircases from the grid. In
        // particular, leave a dragged middle grip sideways instead of reversing
        // up the incoming leg or producing an unnecessary U-shaped detour.
        let elbows = [[start, CGPoint(x: end.x, y: start.y), end], [start, CGPoint(x: start.x, y: end.y), end]].map { vertices in
            vertices.enumerated().filter { i, p in i == 0 || hypot(p.x - vertices[i - 1].x, p.y - vertices[i - 1].y) > 0.001 }.map(\.element)
        }
        for vertices in elbows {
            guard vertices.count > 1 else { return [start] }
            let first = vertices[1], prior = vertices[vertices.count - 2]
            if let departure, (first.x - start.x) * departure.dx + (first.y - start.y) * departure.dy < -0.001 { continue }
            if let arrival, (end.x - prior.x) * arrival.dx + (end.y - prior.y) * arrival.dy < -0.001 { continue }
            if (1..<vertices.count).allSatisfy({ i in !obstacles.contains { crosses(vertices[i - 1], vertices[i], rect: $0) } }) { return vertices }
        }
        let xs = Array(Set([start.x, end.x] + obstacles.flatMap { [$0.minX, $0.maxX] })).sorted()
        let ys = Array(Set([start.y, end.y] + obstacles.flatMap { [$0.minY, $0.maxY] })).sorted()
        let nodes = ys.flatMap { y in xs.map { CGPoint(x: $0, y: y) } }
        let valid = nodes.map { p in !obstacles.contains { $0.insetBy(dx: 0.0001, dy: 0.0001).contains(p) } }
        guard let first = nodes.firstIndex(of: start), let last = nodes.firstIndex(of: end), valid[first], valid[last] else { return [start, end] }
        var cost = Array(repeating: CGFloat.infinity, count: nodes.count), previous = Array(repeating: -1, count: nodes.count), visited = Set<Int>()
        cost[first] = 0
        let reversalPenalty = max(100, abs(start.x - end.x) + abs(start.y - end.y) + 100)
        while let current = nodes.indices.filter({ !visited.contains($0) && valid[$0] }).min(by: { cost[$0] < cost[$1] }), cost[current].isFinite {
            if current == last { break }; visited.insert(current)
            let x = current % xs.count, y = current / xs.count
            let neighbors = [x > 0 ? current - 1 : -1, x + 1 < xs.count ? current + 1 : -1, y > 0 ? current - xs.count : -1, y + 1 < ys.count ? current + xs.count : -1]
            for next in neighbors where next >= 0 && valid[next] && !visited.contains(next) {
                let a = nodes[current], b = nodes[next]
                guard !obstacles.contains(where: { crosses(a, b, rect: $0) }) else { continue }
                var candidate = cost[current] + abs(a.x - b.x) + abs(a.y - b.y)
                // Avoid doubled-back stubs/dangling tails at ports and at the
                // middle grip when equally short perpendicular routes exist.
                if current == first, let departure, (b.x - a.x) * departure.dx + (b.y - a.y) * departure.dy < -0.001 { candidate += reversalPenalty }
                if next == last, let arrival, (b.x - a.x) * arrival.dx + (b.y - a.y) * arrival.dy < -0.001 { candidate += reversalPenalty }
                if candidate < cost[next] { cost[next] = candidate; previous[next] = current }
            }
        }
        guard cost[last].isFinite else { return [start, end] }
        var result = [end], cursor = last
        while cursor != first { cursor = previous[cursor]; guard cursor >= 0 else { return [start, end] }; result.append(nodes[cursor]) }
        return result.reversed()
    }
}
