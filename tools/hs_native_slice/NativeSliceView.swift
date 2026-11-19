// SPDX-License-Identifier: GPL-3.0-or-later
// Read-only AppKit window for the all-Haskell native slice's NDSF/NDSE stream
// (same record layout as tools/hs_gpu_view, which stays untouched): "NDSF",
// u32 frame, u32 0, u32 0, u32 0, then 256x384 BGRA; "NDSE", u32 status,
// u32 message bytes, u64 0, then UTF-8 text, always last. It shows only frames
// the Haskell GPU completed; when the stream ends the last frame stays up and
// is labelled STOPPED. No input is sent: the slice has no keypad/touch path.
import AppKit

let width = 256, height = 384, headerSize = 20
let baseTitle = "All-Haskell native slice: Clash ARM9 slice + Haskell GPU (no melonDS)"

final class Viewer: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width * 2, height: height * 2 + 40),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    let imageView = NSImageView()
    let status = NSTextField(wrappingLabelWithString: "waiting for the first completed Haskell GPU frame…")

    func applicationDidFinishLaunching(_ note: Notification) {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let stack = NSStackView(views: [imageView, status])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        status.setContentHuggingPriority(.required, for: .vertical)
        window.contentView = stack
        window.title = baseTitle
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Thread.detachNewThread { self.readLoop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func readExactly(_ n: Int) -> Data? {
        var out = Data(capacity: n)
        while out.count < n {
            let chunk = FileHandle.standardInput.readData(ofLength: n - out.count)
            if chunk.isEmpty { return nil }
            out.append(chunk)
        }
        return out
    }

    func readLoop() {
        var shown = 0
        var last = "no frame was received"
        while let head = readExactly(headerSize) {
            let u = { (i: Int) in head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian } }
            if head.prefix(4) == Data("NDSE".utf8) {
                let text = readExactly(Int(u(8))).flatMap { String(data: $0, encoding: .utf8) } ?? "unreadable terminal message"
                stopped(u(4) == 0 ? "producer finished: \(text)" : "ERROR: \(text)", last: last, error: u(4) != 0)
                return
            }
            guard head.prefix(4) == Data("NDSF".utf8) else { stopped("bad record magic", last: last, error: true); return }
            let frame = u(4)
            guard let pixels = readExactly(width * height * 4), let cg = makeImage(pixels) else {
                stopped("truncated or unusable frame", last: last, error: true); return
            }
            shown += 1
            last = "last shown: device frame \(frame) (#\(shown))"
            if let path = ProcessInfo.processInfo.environment["NDS_VIEW_SNAPSHOT"],
               let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            let image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
            let text = last
            DispatchQueue.main.async {
                self.imageView.image = image
                self.status.stringValue = "RUNNING (guest-time frames, not wall-clock paced) — " + text
                self.window.title = "\(baseTitle) — frame \(frame)"
            }
        }
        stopped("producer exited without a terminal record", last: last, error: true)
    }

    func stopped(_ why: String, last: String, error: Bool) {
        DispatchQueue.main.async {
            self.status.stringValue = "STOPPED — \(why) | \(last)"
            self.status.textColor = error ? .systemRed : .labelColor
            self.window.title = "\(baseTitle) — \(error ? "STOPPED (ERROR)" : "STOPPED")"
        }
    }

    func makeImage(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                           | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

let app = NSApplication.shared
let viewer = Viewer()
app.delegate = viewer
app.setActivationPolicy(.regular)
app.run()
