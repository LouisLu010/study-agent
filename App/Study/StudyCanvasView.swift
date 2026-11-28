import StudyKit
import SwiftData
import SwiftUI

struct StudyCanvasesView: View {
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @Query(sort: \StudyCanvas.updatedAt, order: .reverse) private var canvases: [StudyCanvas]
    @State private var title = ""
    @State private var creating = false
    @State private var errorText: String?
    private var visible: [StudyCanvas] { canvases.filter { !toasts.isHidden($0) } }

    var body: some View {
        List {
            ForEach(visible) { canvas in
                NavigationLink { StudyCanvasView(canvas: canvas) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(canvas.title).font(.headline)
                        Text("\(canvas.sortedItems.count) 份内容 · \(canvas.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let removed = offsets.map { visible[$0] }
                toasts.delete(removed, scope: .canvases) {
                    for canvas in removed { context.delete(canvas) }; save()
                }
            }
        }
        .overlay { if visible.isEmpty { ContentUnavailableView("建立一个专题空间", systemImage: "rectangle.3.group", description: Text("把原题、图表、知识卡和手写放在一起。")) } }
        .toastBar(.canvases)
        .navigationTitle("学习画布")
        .toolbar { Button("新建画布", systemImage: "plus") { title = ""; creating = true } }
        .alert("新建画布", isPresented: $creating) {
            TextField("专题名称", text: $title)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                context.insert(StudyCanvas(title: name.isEmpty ? "学习画布" : name)); save()
            }
        }
        .studyError($errorText)
    }

    private func save() {
        do { try context.save() } catch { errorText = ChatErrorDescription.describe(error) }
    }
}

private enum CanvasSheet: Identifiable {
    case material, text(CanvasItem?), drawing(CanvasItem?), ask, source(StudyReference), preview(CanvasItem)
    var id: String {
        switch self {
        case .material: "material"
        case let .text(item): "text-\(item?.id.uuidString ?? "new")"
        case let .drawing(item): "drawing-\(item?.id.uuidString ?? "new")"
        case .ask: "ask"
        case let .source(ref): "source-\(ref.id)"
        case let .preview(item): "preview-\(item.id)"
        }
    }
}

struct StudyCanvasView: View {
    @Bindable var canvas: StudyCanvas
    @Environment(\.modelContext) private var context
    @Environment(ToastCenter.self) private var toasts
    @State private var selection: Set<UUID> = []
    @State private var selecting = false
    @State private var box: CGRect?
    @State private var panStart: MapPoint?
    @State private var sheet: CanvasSheet?
    @State private var errorText: String?
    @State private var renaming = false
    @State private var name = ""
    @State private var viewSize = CGSize.zero
    private var visibleItems: [CanvasItem] { canvas.sortedItems.filter { !toasts.isHidden($0) } }

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    Color(.systemGroupedBackground)
                        .contentShape(Rectangle())
                        .gesture(backgroundDrag)
                    ForEach(visibleItems) { item in
                        CanvasTile(item: item, selected: selection.contains(item.id), selecting: selecting,
                                   visible: isOnScreen(item, size: proxy.size),
                                   zoom: canvas.zoom, onSelect: { toggle(item.id) },
                                   onOpen: { sheet = .preview(item) }, onEdit: {
                            sheet = item.drawingData == nil ? .text(item) : .drawing(item)
                        }, onMove: save, onDelete: {
                            selection.remove(item.id)
                            toasts.delete([item], scope: .canvases) { context.delete(item); save() }
                        })
                            .frame(width: CanvasSelection.width, height: CanvasSelection.height)
                            .scaleEffect(canvas.zoom)
                            .position(x: item.x * canvas.zoom + canvas.offsetX + proxy.size.width / 2,
                                      y: item.y * canvas.zoom + canvas.offsetY + proxy.size.height / 2)
                    }
                    if let box {
                        Rectangle().fill(Color.accentColor.opacity(0.12))
                            .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5])))
                            .frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                            .allowsHitTesting(false)
                    }
                    if visibleItems.isEmpty {
                        ContentUnavailableView("添加你的学习内容", systemImage: "plus.rectangle.on.rectangle", description: Text("添加原题、知识卡、会话消息或手写，再拖动标题栏自由摆放。"))
                            .frame(width: proxy.size.width, height: proxy.size.height).allowsHitTesting(false)
                    }
                }
                .clipped()
                .onAppear { viewSize = proxy.size }
                .onChange(of: proxy.size) { viewSize = proxy.size }
            }
        }
        .navigationTitle(canvas.title)
        .toastBar(.canvases)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Button("已有内容", systemImage: "books.vertical") { sheet = .material }
                Button("文字", systemImage: "text.alignleft") { sheet = .text(nil) }
                Button("手写", systemImage: "pencil.tip") { sheet = .drawing(nil) }
                Button("重命名", systemImage: "pencil") { name = canvas.title; renaming = true }
            } label: { Label("添加内容", systemImage: "plus") }
        }
        .sheet(item: $sheet) { route in
            switch route {
            case .material: StudyMaterialPicker { add($0) }
            case let .text(item): CanvasTextSheet(item: item) { title, text in
                if let item { item.title = title; item.content = text; item.componentStateJSON = ""; save() }
                else { add(StudyMaterial(title: title, content: text)) }
            }
            case let .drawing(item):
                HandwritingSheet(onDone: { _ in }, initialDrawing: item?.drawingData, onDrawingDone: { drawing, jpeg in
                    if let item {
                        for image in item.images ?? [] { context.delete(image) }
                        let image = StoredImage(data: jpeg, contentType: "image/jpeg")
                        context.insert(image); image.canvasItem = item
                        item.content = "![](sa-asset:\(image.id.uuidString))"
                        item.drawingData = drawing; save()
                    } else if let item = add(StudyMaterial(title: "手写", content: "", images: [.init(data: jpeg)])) {
                        item.drawingData = drawing; save()
                    }
                })
            case .ask: CanvasAskSheet(canvas: canvas, selected: selection)
            case let .source(reference): StudyReferenceSheet(reference: reference)
            case let .preview(item): CanvasItemSheet(item: item)
            }
        }
        .alert("重命名画布", isPresented: $renaming) {
            TextField("专题名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { canvas.title = name; save() }
            }
        }
        .studyError($errorText)
    }

    private var controls: some View {
        HStack {
            Button(selecting ? "完成选择" : "选择", systemImage: "selection.pin.in.out") { selecting.toggle() }
            Spacer()
            Button("缩小", systemImage: "minus.magnifyingglass") { canvas.zoom = CanvasSelection.clampedZoom(canvas.zoom / 1.2); save() }.labelStyle(.iconOnly)
            Button("居中") { canvas.offsetX = 0; canvas.offsetY = 0; canvas.zoom = 1; save() }.font(.caption)
            Button("放大", systemImage: "plus.magnifyingglass") { canvas.zoom = CanvasSelection.clampedZoom(canvas.zoom * 1.2); save() }.labelStyle(.iconOnly)
            Button("提问 \(selection.count)", systemImage: "sparkles") { sheet = .ask }.disabled(selection.isEmpty)
        }
        .font(.subheadline).padding(.horizontal).padding(.vertical, 10)
    }

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 4).onChanged { value in
            if selecting {
                box = CGRect(x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                             width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
            } else {
                if panStart == nil { panStart = MapPoint(x: canvas.offsetX, y: canvas.offsetY) }
                canvas.offsetX = (panStart?.x ?? 0) + value.translation.width
                canvas.offsetY = (panStart?.y ?? 0) + value.translation.height
            }
        }.onEnded { value in
            if selecting {
                let offset = MapPoint(x: canvas.offsetX + viewSize.width / 2, y: canvas.offsetY + viewSize.height / 2)
                selection = CanvasSelection.selected(items: visibleItems.map { .init(id: $0.id, center: MapPoint(x: $0.x, y: $0.y)) },
                    from: CanvasSelection.world(MapPoint(x: value.startLocation.x, y: value.startLocation.y), offset: offset, zoom: canvas.zoom),
                    to: CanvasSelection.world(MapPoint(x: value.location.x, y: value.location.y), offset: offset, zoom: canvas.zoom))
                box = nil
            } else { panStart = nil; save() }
        }
    }

    private func toggle(_ id: UUID) { if !selection.insert(id).inserted { selection.remove(id) } }

    private func isOnScreen(_ item: CanvasItem, size: CGSize) -> Bool {
        let x = item.x * canvas.zoom + canvas.offsetX + size.width / 2
        let y = item.y * canvas.zoom + canvas.offsetY + size.height / 2
        let margin = max(CanvasSelection.width, CanvasSelection.height) * canvas.zoom
        return x > -margin && x < size.width + margin && y > -margin && y < size.height + margin
    }

    @discardableResult private func add(_ material: StudyMaterial) -> CanvasItem? {
        guard canvas.sortedItems.count < 40 else { errorText = "每张画布最多保存 40 份内容，请新建另一个专题。"; return nil }
        do {
            let shift = Double(canvas.sortedItems.count % 5) * 28
            return try StudyCanvasStore.add(material, to: canvas,
                at: MapPoint(x: -canvas.offsetX / canvas.zoom + shift, y: -canvas.offsetY / canvas.zoom + shift), context: context)
        } catch { errorText = ChatErrorDescription.describe(error); return nil }
    }

    private func save() {
        canvas.updatedAt = .now
        do { try context.save() } catch { errorText = ChatErrorDescription.describe(error) }
    }
}

private struct CanvasTile: View {
    @Bindable var item: CanvasItem
    let selected: Bool
    let selecting: Bool
    let visible: Bool
    let zoom: Double
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    @State private var start: MapPoint?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onSelect) { Image(systemName: selected ? "checkmark.circle.fill" : "circle") }.accessibilityLabel("选择\(item.title)")
                Text(item.title).font(.headline).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                        if start == nil { start = MapPoint(x: item.x, y: item.y) }
                        item.x = (start?.x ?? 0) + value.translation.width / zoom
                        item.y = (start?.y ?? 0) + value.translation.height / zoom
                    }.onEnded { _ in start = nil; onMove() })
                Menu {
                    Button("打开", systemImage: "arrow.up.left.and.arrow.down.right", action: onOpen)
                    Button("编辑副本", systemImage: "pencil", action: onEdit)
                    Button("移除", systemImage: "trash", role: .destructive, action: onDelete)
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("内容操作")
            }.padding(12)
            Divider()
            Group {
                if visible { CanvasItemContent(item: item) }
                else { Color.clear }
            }
                .allowsHitTesting(!selecting)
                .overlay { if selecting { Color.clear.contentShape(Rectangle()).onTapGesture(perform: onSelect) } }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
        .accessibilityIdentifier("canvas-item-\(item.id)")
    }
}

struct CanvasItemContent: View {
    let item: CanvasItem
    @Environment(\.modelContext) private var context
    @State private var height: CGFloat = 180
    @State private var handle = WebViewHandle()
    @State private var errorText: String?
    var body: some View {
        ScrollView {
            MessageWebView(messageID: item.id, content: item.content, isStreaming: false, componentStateJSON: item.componentStateJSON,
                           height: $height, onComponentState: { key, state in
                item.componentStateJSON = ComponentStateStore.updating(item.componentStateJSON, key: key, state: state)
                do { try context.save() } catch { errorText = ChatErrorDescription.describe(error) }
            }, groupedSurface: true, handle: handle)
            .id(item.content)
            .frame(height: height).padding(10)
        }
        .onChange(of: item.componentStateJSON) { old, new in
            let keys = Set(ComponentStateStore.decode(old).keys).union(ComponentStateStore.decode(new).keys)
            for key in keys { handle.applyState(key: key, stateJSON: new) }
        }
        .studyError($errorText)
    }
}

private struct CanvasItemSheet: View {
    let item: CanvasItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack {
                if let reference = item.sourceReference { StudyReferenceStrip(references: [reference]).padding(.horizontal) }
                if !item.sourceLocation.isEmpty { Text(item.sourceLocation).font(.caption).foregroundStyle(.secondary) }
                CanvasItemContent(item: item)
            }
            .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
    }
}

private struct CanvasTextSheet: View {
    let item: CanvasItem?
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $title)
                TextEditor(text: $content).frame(minHeight: 260).accessibilityLabel("正文")
            }
            .navigationTitle(item == nil ? "添加文字" : "编辑副本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    onSave(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "文字" : title, content); dismiss()
                }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .onAppear { title = item?.title ?? ""; content = item?.content ?? "" }
        }
    }
}

private struct CanvasAskSheet: View {
    let canvas: StudyCanvas
    let selected: Set<UUID>
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(GenerationCenter.self) private var generation
    @Environment(AppNavigation.self) private var navigation
    @State private var question = ""
    @State private var model: ChatModel?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("选中的材料") {
                    ForEach(canvas.sortedItems.filter { selected.contains($0.id) }) { item in Text(item.title) }
                }
                Section("你的问题") { TextEditor(text: $question).frame(minHeight: 120) }
                ModelPickerMenu(selection: $model)
                Text("选中内容的文字和图片将发送给所选模型。提问会保存为独立会话。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("对选中内容提问")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("提问") {
                    guard let model else { return }
                    do {
                        let conversation = try StudyCanvasStore.ask(question, selected: selected, canvas: canvas, model: model,
                                                                   context: context, generation: generation)
                        navigation.selection = .conversation(conversation); dismiss()
                    } catch { errorText = ChatErrorDescription.describe(error) }
                }.disabled(model == nil || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .task { model = ModelLookup.defaultModel(in: context) }
            .studyError($errorText)
        }
    }
}

extension View {
    func studyError(_ message: Binding<String?>) -> some View {
        alert("提示", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(message.wrappedValue ?? "") }
    }
}
