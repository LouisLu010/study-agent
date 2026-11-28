import StudyKit
import SwiftData
import SwiftUI

/// 关系图（第十版，见 GLOSSARY「关系图」）：一个科目的知识卡是节点、关联是连线。
/// 可以拖动、双指缩放、拖节点；点节点弹出那张卡的弹窗，点连线显示种类和理由。
/// 排布在 StudyKit 的 `ConceptMapLayout` 里，画面是原生 SwiftUI。
struct ConceptMapView: View {
    @Binding var subject: Subject?
    /// 从某张卡进入（弹窗里点了"在关系图里看"）。用一次就清掉。
    @Binding var focusRequest: UUID?

    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \ConceptCard.createdAt) private var allCards: [ConceptCard]
    @Query private var allLinks: [ConceptLink]

    /// 排布坐标（缩放为 1 时的点，原点在图的中心）。
    @State private var positions: [UUID: MapPoint] = [:]
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinchStart: CGFloat?
    @State private var panStart: CGSize?
    @State private var dragging: (id: UUID, start: MapPoint)?
    @State private var topics: Set<String> = []
    /// 只看这张卡周围两步以内的卡。
    @State private var focusRoot: UUID?
    /// 弹窗里正在看的卡（高亮它和直接相连的卡）。
    @State private var selectedID: UUID?
    /// 弹窗是从哪张卡打开的；弹窗里换卡时它不变，弹窗不会重新弹一次。
    @State private var popupRoot: UUID?
    @State private var anchor: CGRect = .zero
    /// 拖动从节点上开始时，画布不跟着平移。
    @State private var panBlocked = false
    /// 刚从"在关系图里看"切过来的科目：这次科目变化不清掉聚焦。
    @State private var focusingSubject: Subject?
    @State private var bubble: EdgeBubble?
    @State private var viewSize: CGSize = .zero
    @State private var didFit = false

    private struct EdgeBubble: Equatable {
        let edge: LinkEdge
        let reason: String
        let point: CGPoint
    }

    static let nodeSize = CGSize(width: 150, height: 50)

    // MARK: - 数据

    private var subjects: [Subject] {
        let present = Set(allCards.filter { !toasts.isHidden($0) }.map { $0.subject ?? .other })
        return Subject.allCases.filter(present.contains)
    }

    private var currentSubject: Subject? { subject ?? subjects.first }

    private var subjectCards: [ConceptCard] {
        guard let currentSubject else { return [] }
        return allCards.filter { !toasts.isHidden($0) && ($0.subject ?? .other) == currentSubject }
    }

    private var subjectEdges: [(edge: LinkEdge, reason: String)] {
        let ids = Set(subjectCards.map(\.id))
        return allLinks.filter { !$0.dismissed }.compactMap { link in
            guard let edge = ConceptCardStore.edge(link), ids.contains(edge.from), ids.contains(edge.to) else { return nil }
            return (edge, link.reason)
        }
    }

    private var visibleCards: [ConceptCard] {
        var cards = subjectCards
        if !topics.isEmpty { cards = cards.filter { topics.contains($0.topic) } }
        if let focusRoot, subjectCards.contains(where: { $0.id == focusRoot }) {
            let near = LinkRules.neighborhood(of: focusRoot, hops: 2, edges: subjectEdges.map(\.edge))
            cards = cards.filter { near.contains($0.id) }
        }
        return cards
    }

    /// 选中节点和直接相连的节点：弹窗打开时它们保持清楚，其余模糊变暗。
    private var highlighted: Set<UUID>? {
        guard let selectedID else { return nil }
        return LinkRules.neighborhood(of: selectedID, hops: 1, edges: subjectEdges.map(\.edge))
    }

    private var layoutKey: String {
        let ids = subjectCards.map { "\($0.id.uuidString)\($0.mapX ?? .nan)\($0.mapY ?? .nan)" }.sorted().joined()
        let edges = subjectEdges.map { "\($0.edge.from)\($0.edge.to)\($0.edge.kind.rawValue)" }.sorted().joined()
        return ids + "|" + edges
    }

    // MARK: - 画面

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { proxy in
                ZStack {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(backgroundTap)
                    if visibleCards.isEmpty {
                        ContentUnavailableView(subjectCards.isEmpty ? "这个科目还没有知识卡" : "没有符合条件的知识卡", systemImage: "point.3.connected.trianglepath.dotted")
                    } else {
                        map(in: proxy.size)
                    }
                    if let bubble {
                        edgeBubble(bubble)
                    }
                }
                .clipped()
                .simultaneousGesture(pan)
                .simultaneousGesture(pinch)
                .onAppear {
                    viewSize = proxy.size
                    if !didFit { didFit = fit(animated: false) }
                }
                .onChange(of: proxy.size) { viewSize = proxy.size }
                .popover(
                    isPresented: Binding(get: { popupRoot != nil }, set: { if !$0 { popupRoot = nil; selectedID = nil } }),
                    attachmentAnchor: .rect(.rect(anchor))
                ) {
                    if let id = popupRoot {
                        ConceptCardPopup(startID: id, onCurrentChange: follow)
                    }
                }
            }
        }
        .task(id: layoutKey) { relayout() }
        .onChange(of: currentSubject) {
            if let focusingSubject, focusingSubject == currentSubject {
                self.focusingSubject = nil
                return
            }
            topics = []
            focusRoot = nil
            selectedID = nil
            popupRoot = nil
            bubble = nil
            didFit = false
            relayout()
        }
        .onChange(of: focusRequest) { consumeFocusRequest() }
        .onAppear { consumeFocusRequest() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if subjects.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(subjects) { item in
                            SubjectChip(title: item.rawValue, isSelected: currentSubject == item) { subject = item }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.l)
                }
            }
            HStack(spacing: Theme.Spacing.m) {
                Menu {
                    Button("全部知识点") { topics = [] }
                    Divider()
                    ForEach(Array(Set(subjectCards.map(\.topic))).sorted(), id: \.self) { topic in
                        Button {
                            if topics.contains(topic) { topics.remove(topic) } else { topics.insert(topic) }
                        } label: {
                            Label(topic, systemImage: topics.contains(topic) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Label(topics.isEmpty ? "全部知识点" : "\(topics.count) 个知识点", systemImage: "line.3.horizontal.decrease.circle")
                }
                if let focusRoot, let card = subjectCards.first(where: { $0.id == focusRoot }) {
                    Button {
                        self.focusRoot = nil
                        fit(animated: true)
                    } label: {
                        Label("\(card.title) 周围 · 看全部", systemImage: "xmark.circle.fill")
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button("适应屏幕", systemImage: "arrow.up.left.and.arrow.down.right") { fit(animated: true) }
                    .labelStyle(.iconOnly)
            }
            .font(.subheadline)
            .padding(.horizontal, Theme.Spacing.l)
        }
        .padding(.vertical, Theme.Spacing.s)
    }

    private func map(in size: CGSize) -> some View {
        let cards = visibleCards
        let ids = Set(cards.map(\.id))
        let edges = subjectEdges.filter { ids.contains($0.edge.from) && ids.contains($0.edge.to) }
        let colors = ConceptCardStore.topicColors(subjectCards.map(\.topic))
        let focus = highlighted
        let blur = focus != nil && !reduceTransparency ? 6.0 : 0
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let isSharp: (LinkEdge) -> Bool = { edge in
            guard focus != nil, let selectedID else { return true }
            return edge.from == selectedID || edge.to == selectedID
        }
        let sharpEdges = edges.filter { item in isSharp(item.edge) }
        let dimEdges = edges.filter { item in !isSharp(item.edge) }
        return ZStack {
            edgeCanvas(dimEdges.map(\.edge), center: center)
                .blur(radius: blur)
                .opacity(focus == nil ? 1 : 0.3)
            edgeCanvas(sharpEdges.map(\.edge), center: center)
            ForEach(cards) { card in
                let isLit = focus?.contains(card.id) ?? true
                node(card, color: colors[card.topic] ?? .accentColor, selected: card.id == selectedID)
                    .blur(radius: isLit ? 0 : blur)
                    .opacity(isLit ? 1 : 0.35)
                    .position(point(card.id, center: center))
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(scale)
        .offset(offset)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: selectedID)
    }

    private func node(_ card: ConceptCard, color: Color, selected: Bool) -> some View {
        Text(card.title)
            .font(.subheadline.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(width: Self.nodeSize.width, height: Self.nodeSize.height)
            .background(color.opacity(selected ? 0.35 : 0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(color, lineWidth: selected ? 2.5 : 1.2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .onTapGesture { open(card.id) }
            .gesture(nodeDrag(card))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("打开这张知识卡")
            .accessibilityIdentifier(selected ? "concept-map-selected-card" : "concept-map-card-\(card.id.uuidString)")
    }

    /// 连线。前置是实线带箭头，对比是虚线不带箭头，应用是点线带箭头，三种同一个颜色。
    ///
    /// Canvas 只在自己的边框里画、超出的部分被裁掉。以前它和视图一样大，节点排到视图外面（图比屏幕大、缩小来看）时，
    /// 节点照样显示（`.position` 不裁剪），连线却被裁掉，看起来像"有时候连线画不出来"。
    /// 现在 Canvas 的边框盖住所有节点（再留一圈余量），按这个边框换算坐标。
    private func edgeCanvas(_ edges: [LinkEdge], center: CGPoint) -> some View {
        let bounds = Self.canvasBounds(for: edges.flatMap { [positions[$0.from], positions[$0.to]] }.compactMap { $0 })
        let origin = CGPoint(x: center.x + bounds.minX, y: center.y + bounds.minY)
        return Canvas { canvas, _ in
            for edge in edges {
                guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
                let pa = CGPoint(x: a.x - bounds.minX, y: a.y - bounds.minY)
                let pb = CGPoint(x: b.x - bounds.minX, y: b.y - bounds.minY)
                let start = Self.boundaryPoint(from: pa, toward: pb)
                let end = Self.boundaryPoint(from: pb, toward: pa)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                let dash: [CGFloat] = switch edge.kind {
                case .prerequisite: []
                case .contrast: [7, 5]
                case .application: [2, 5]
                }
                let color = Color.secondary
                canvas.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: dash))
                if edge.kind.isDirected {
                    canvas.fill(Self.arrowHead(at: end, from: start), with: .color(color))
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height)
        .position(x: origin.x + bounds.width / 2, y: origin.y + bounds.height / 2)
        .allowsHitTesting(false)
    }

    /// 盖住这些点的矩形（排布坐标），四周留出节点的一半大小加箭头的余量。
    static func canvasBounds(for points: [MapPoint]) -> CGRect {
        guard let first = points.first else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let margin = Double(max(nodeSize.width, nodeSize.height))
        return CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + margin * 2, height: maxY - minY + margin * 2)
    }

    private func edgeBubble(_ bubble: EdgeBubble) -> some View {
        let from = subjectCards.first { $0.id == bubble.edge.from }?.title ?? ""
        let to = subjectCards.first { $0.id == bubble.edge.to }?.title ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(from) \(bubble.edge.kind.isDirected ? "→" : "—") \(to)")
                .font(.footnote.weight(.semibold))
            Text(bubble.edge.kind.displayName + (bubble.reason.isEmpty ? "" : " · " + bubble.reason))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(maxWidth: 280)
        .position(x: bubble.point.x, y: bubble.point.y - 36)
        .transition(.opacity)
    }

    // MARK: - 坐标

    private func cg(_ p: MapPoint, _ center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + p.x, y: center.y + p.y)
    }

    private func point(_ id: UUID, center: CGPoint) -> CGPoint {
        cg(positions[id] ?? MapPoint(x: 0, y: 0), center)
    }

    /// 排布坐标 → 屏幕上（这个视图里）的点。
    private func screenPoint(_ p: MapPoint) -> CGPoint {
        CGPoint(x: viewSize.width / 2 + offset.width + p.x * scale, y: viewSize.height / 2 + offset.height + p.y * scale)
    }

    /// 屏幕上的点 → 排布坐标。
    private func mapPoint(_ p: CGPoint) -> MapPoint {
        MapPoint(x: (p.x - viewSize.width / 2 - offset.width) / scale, y: (p.y - viewSize.height / 2 - offset.height) / scale)
    }

    private func nodeRect(_ id: UUID) -> CGRect {
        let center = screenPoint(positions[id] ?? MapPoint(x: 0, y: 0))
        let size = CGSize(width: Self.nodeSize.width * scale, height: Self.nodeSize.height * scale)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// 从节点中心朝另一个节点走，走到节点边框上的那一点。
    static func boundaryPoint(from center: CGPoint, toward other: CGPoint) -> CGPoint {
        let dx = other.x - center.x, dy = other.y - center.y
        guard dx != 0 || dy != 0 else { return center }
        let half = CGSize(width: nodeSize.width / 2 + 4, height: nodeSize.height / 2 + 4)
        let t = min(dx == 0 ? .infinity : half.width / abs(dx), dy == 0 ? .infinity : half.height / abs(dy))
        return CGPoint(x: center.x + dx * min(t, 1), y: center.y + dy * min(t, 1))
    }

    static func arrowHead(at tip: CGPoint, from start: CGPoint) -> Path {
        let angle = atan2(tip.y - start.y, tip.x - start.x)
        let length: CGFloat = 10, spread: CGFloat = .pi / 7
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        path.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        path.closeSubpath()
        return path
    }

    /// 点到线段的距离（排布坐标）。
    static func distance(_ p: MapPoint, toSegment a: MapPoint, _ b: MapPoint) -> Double {
        let ab = b - a, ap = p - a
        let lengthSquared = ab.x * ab.x + ab.y * ab.y
        guard lengthSquared > 0 else { return (p - a).length }
        let t = max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / lengthSquared))
        return (p - (a + ab * t)).length
    }

    // MARK: - 手势

    private var pan: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // 从节点上开始的拖动是拖节点，不平移画布。
                if panStart == nil && !panBlocked {
                    let p = mapPoint(value.startLocation)
                    panBlocked = visibleCards.contains { card in
                        guard let c = positions[card.id] else { return false }
                        return abs(c.x - p.x) <= Self.nodeSize.width / 2 && abs(c.y - p.y) <= Self.nodeSize.height / 2
                    }
                }
                guard dragging == nil, !panBlocked else { return }
                let start = panStart ?? offset
                panStart = start
                offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                bubble = nil
            }
            .onEnded { _ in
                panStart = nil
                panBlocked = false
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? scale
                pinchStart = start
                let minimum = CGFloat(fittedViewport?.minimumScale ?? 0.25)
                scale = min(2.5, max(minimum, start * value.magnification))
                bubble = nil
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// 点空白处：离连线很近就显示这条关联，否则关掉弹窗和气泡。
    private var backgroundTap: some Gesture {
        SpatialTapGesture().onEnded { value in
            let p = mapPoint(value.location)
            let ids = Set(visibleCards.map(\.id))
            let hit = subjectEdges
                .filter { ids.contains($0.edge.from) && ids.contains($0.edge.to) }
                .compactMap { item -> (edge: LinkEdge, reason: String, distance: Double)? in
                    guard let a = positions[item.edge.from], let b = positions[item.edge.to] else { return nil }
                    return (item.edge, item.reason, Self.distance(p, toSegment: a, b))
                }
                .min { $0.distance < $1.distance }
            if let hit, hit.distance * scale < 16 {
                withAnimation(.smooth(duration: 0.2)) { bubble = EdgeBubble(edge: hit.edge, reason: hit.reason, point: value.location) }
            } else {
                popupRoot = nil
                selectedID = nil
                withAnimation(.smooth(duration: 0.2)) { bubble = nil }
            }
        }
    }

    private func nodeDrag(_ card: ConceptCard) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let start = dragging?.id == card.id ? dragging!.start : (positions[card.id] ?? MapPoint(x: 0, y: 0))
                dragging = (card.id, start)
                // scaleEffect 里的手势位移已经是缩放前的坐标。
                positions[card.id] = MapPoint(x: start.x + value.translation.width, y: start.y + value.translation.height)
                bubble = nil
            }
            .onEnded { _ in
                if let point = positions[card.id] {
                    ConceptCardStore.pin(card, at: point, context: context)
                }
                dragging = nil
            }
    }

    // MARK: - 操作

    private func open(_ id: UUID) {
        bubble = nil
        // iPhone 上弹窗是底部的半屏面板：先把这个节点移到上半部分，免得被面板挡住。
        if sizeClass == .compact, let p = positions[id] {
            let current = screenPoint(p)
            let goal = CGPoint(x: viewSize.width / 2, y: viewSize.height * 0.22)
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                offset = CGSize(width: offset.width + goal.x - current.x, height: offset.height + goal.y - current.y)
            }
        }
        anchor = nodeRect(id)
        selectedID = id
        popupRoot = id
    }

    /// 弹窗里换成了另一张卡：把图移过去，让那个节点落在弹窗原来指着的位置，弹窗不用挪。
    private func follow(_ id: UUID) {
        if !visibleCards.contains(where: { $0.id == id }) {
            topics = []
            if focusRoot != nil { focusRoot = id }
        }
        guard let target = positions[id] else { return }
        let current = screenPoint(target)
        let goal = CGPoint(x: anchor.midX, y: anchor.midY)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            offset = CGSize(width: offset.width + goal.x - current.x, height: offset.height + goal.y - current.y)
            selectedID = id
        }
    }

    private func consumeFocusRequest() {
        guard let id = focusRequest, let card = allCards.first(where: { $0.id == id }) else { return }
        focusRequest = nil
        let target = card.subject ?? .other
        if currentSubject != target { focusingSubject = target }
        subject = target
        topics = []
        // iPhone 上默认只看这张卡周围两步，iPad 上看整个科目、把它放在中间。
        focusRoot = sizeClass == .compact ? id : nil
        relayout()
        if let p = positions[id] {
            scale = 1
            offset = CGSize(width: -p.x, height: -p.y)
            didFit = true
        }
        popupRoot = nil
        selectedID = nil
    }

    private func relayout() {
        let cards = subjectCards
        let nodes = cards.map { card in
            ConceptMapLayout.Node(id: card.id, pinned: card.pinnedPosition, previous: positions[card.id])
        }
        positions = ConceptMapLayout.layout(nodes, edges: subjectEdges.map(\.edge))
        if !didFit {
            didFit = fit(animated: false)
        }
    }

    /// 缩放和平移到能看到所有显示中的节点。
    private var fittedViewport: ConceptMapLayout.Viewport? {
        ConceptMapLayout.fittedViewport(
            for: visibleCards.compactMap { positions[$0.id] },
            width: viewSize.width, height: viewSize.height,
            nodeWidth: Self.nodeSize.width, nodeHeight: Self.nodeSize.height
        )
    }

    @discardableResult
    private func fit(animated: Bool) -> Bool {
        guard let viewport = fittedViewport else { return false }
        let fitted = CGFloat(viewport.scale)
        let change = {
            scale = fitted
            offset = CGSize(width: -viewport.center.x * fitted, height: -viewport.center.y * fitted)
        }
        if animated && !reduceMotion { withAnimation(.smooth(duration: 0.35), change) } else { change() }
        return true
    }
}
