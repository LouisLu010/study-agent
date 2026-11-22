// 在 macOS 上把 symbols.json 里列的 SF Symbols 导出成 PNG（黑色、透明底），放到 public/symbols/。
// 用法：swift scripts/export-symbols.swift symbols.json public/symbols
// SF Symbols 只能在 Apple 平台上用，导出的图片不进仓库，只在渲染宣传片的那台 Mac 上生成（docs/promo/README.md）。
import AppKit

struct Entry: Decodable {
    let name: String
    let weight: String?
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("用法：swift export-symbols.swift symbols.json 输出目录\n".data(using: .utf8)!)
    exit(2)
}
let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let weights: [String: NSFont.Weight] = ["regular": .regular, "medium": .medium, "semibold": .semibold, "bold": .bold]
// 字号 96 pt 画在边长 1.3 倍字号的正方形里，和 Symbol.tsx 的显示比例一致；按 2 倍像素导出。
let pointSize: CGFloat = 96
let canvas = (pointSize * 1.3).rounded()
let pixels = Int(canvas * 2)

var failed = false
for entry in entries {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weights[entry.weight ?? "regular"] ?? .regular)
    guard let image = NSImage(systemSymbolName: entry.name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
        print("✗ 系统里没有 \(entry.name)")
        failed = true
        continue
    }
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { exit(1) }
    bitmap.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let size = image.size
    image.draw(in: NSRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2, width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: output.appendingPathComponent("\(entry.name).png"))
    print("✓ \(entry.name)")
}
exit(failed ? 1 : 0)
