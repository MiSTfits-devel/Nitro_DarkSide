// AppKit window for clash/test/TraceView.hs output on stdin.
//
// It only displays frames the Haskell renderer produced; it never generates,
// substitutes or repeats pixels from another renderer. When the stream ends,
// the last Haskell frame stays visible and the status line says so.
//
// Input: a connected GameController pad (plus an optional keyboard), and the
// mouse on the bottom screen as the touchscreen, are written to the 16-byte
// control file named by NDS_VIEW_INPUT, which melonds_fbdump --input polls
// before every emulated frame ("NDSI", key mask, touch, sequence).
import AppKit
import GameController

let width = 256, height = 384, headerSize = 20
let frameBytes = width * height * 4
let baseTitle = "Haskell GPU render of live melonDS-CPU stream (open loop; not a closed-loop console)"

// melonDS SetKeyMask bit order.
enum Key: Int { case a = 0, b, select, start, right, left, up, down, r, l, x, y }

/// Control file: viewer writes bytes 0-15, melonds_fbdump writes the sequence
/// it ran a whole frame with at bytes 16-19. A press or touch shorter than one
/// emulated frame stays latched until that ack, so taps are not dropped while
/// the pipe throttles melonDS to the Haskell renderer's speed.
final class InputChannel {
    private let fd: Int32
    private let lock = NSLock()
    private var pad: UInt32 = 0, keyboard: UInt32 = 0, seq: UInt32 = 0
    private var touch: UInt32 = 0
    private var latchedKeys: UInt32 = 0, latchedTouch: UInt32 = 0, latchSeq: UInt32 = 0
    var onChange: ((String) -> Void)?

    init(path: String?) {
        fd = path.map { open($0, O_RDWR | O_CREAT, 0o644) } ?? -1
        publish()
    }
    var enabled: Bool { fd >= 0 }

    func setPad(_ bits: UInt32) { lock.lock(); latch(newKeys: bits & ~pad); pad = bits; lock.unlock(); publish() }
    func setKeyboard(_ key: Key, _ down: Bool) {
        lock.lock()
        let bit = UInt32(1) << UInt32(key.rawValue)
        if down { latch(newKeys: bit & ~keyboard); keyboard |= bit } else { keyboard &= ~bit }
        lock.unlock(); publish()
    }
    func setTouch(_ point: (Int, Int)?) {
        lock.lock()
        if let (x, y) = point {
            touch = 0x8000_0000 | UInt32(max(0, min(255, x))) | UInt32(max(0, min(191, y))) << 8
            latchedTouch = touch; latchSeq = seq &+ 1
        } else { touch = 0 }
        lock.unlock(); publish()
    }
    private func latch(newKeys: UInt32) {
        if newKeys != 0 { latchedKeys |= newKeys; latchSeq = seq &+ 1 }
    }

    /// Drop latches once melonDS has run a frame with the latched state.
    func poll() {
        guard fd >= 0 else { return }
        var ack: UInt32 = 0
        guard pread(fd, &ack, 4, 16) == 4 else { return }
        lock.lock()
        let clear = (latchedKeys != 0 || latchedTouch != 0) && Int32(bitPattern: ack &- latchSeq) >= 0
        if clear { latchedKeys = 0; latchedTouch = 0 }
        lock.unlock()
        if clear { publish() }
    }

    private func publish() {
        lock.lock()
        seq &+= 1
        let held = pad | keyboard
        let keys = held | latchedKeys
        let t = touch != 0 ? touch : latchedTouch
        let cur = touch
        var words: [UInt32] = [0x4953_444E, (~keys) & 0xFFF, t, seq]   // "NDSI" little-endian
        lock.unlock()
        if fd >= 0 { _ = words.withUnsafeMutableBytes { pwrite(fd, $0.baseAddress, 16, 0) } }
        let names = ["A", "B", "Sel", "Start", "→", "←", "↑", "↓", "R", "L", "X", "Y"]
        let down = (0..<12).filter { held & (1 << UInt32($0)) != 0 }.map { names[$0] }
        let touchText = cur & 0x8000_0000 != 0 ? "touch (\(cur & 0xFF),\((cur >> 8) & 0xFF))" : "touch up"
        onChange?("held [\(down.joined(separator: " "))] \(touchText)")
    }
}

final class TouchImageView: NSImageView {
    var input: InputChannel?
    private var touching = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Map a view point to bottom-screen pixels through the aspect-fit image
    /// rectangle (AppKit points; Retina backing scale does not change it).
    func bottomScreenPixel(_ p: NSPoint) -> (Int, Int, Bool) {
        let scale = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        let w = CGFloat(width) * scale, h = CGFloat(height) * scale
        let origin = NSPoint(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2)
        let ix = (p.x - origin.x) / scale
        let iyTop = (isFlipped ? (p.y - origin.y) : (origin.y + h - p.y)) / scale   // 0 = top of top screen
        let inside = ix >= 0 && ix < CGFloat(width) && iyTop >= 192 && iyTop < CGFloat(height)
        return (Int(ix.rounded(.down)), Int((iyTop - 192).rounded(.down)), inside)
    }

    override func mouseDown(with e: NSEvent) {
        let (x, y, inside) = bottomScreenPixel(convert(e.locationInWindow, from: nil))
        guard inside else { return }   // top-screen clicks never touch
        touching = true
        input?.setTouch((x, y))
    }
    override func mouseDragged(with e: NSEvent) {
        guard touching else { return }
        let (x, y, _) = bottomScreenPixel(convert(e.locationInWindow, from: nil))
        input?.setTouch((x, y))    // clamped to 0..255 x 0..191
    }
    override func mouseUp(with e: NSEvent) { release() }
    override func mouseExited(with e: NSEvent) { release() }
    func release() {
        guard touching else { return }
        touching = false
        input?.setTouch(nil)
    }
}

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width * 2, height: height * 2 + 60),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    let imageView = TouchImageView()
    let status = NSTextField(wrappingLabelWithString: "waiting for first Haskell frame…")
    let controls = NSTextField(wrappingLabelWithString: "")
    let input = InputChannel(path: ProcessInfo.processInfo.environment["NDS_VIEW_INPUT"])
    var controllerText = "no game controller detected"
    var inputText = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.input = input
        for label in [status, controls] { label.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
        let stack = NSStackView(views: [imageView, status, controls])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.distribution = .fill
        imageView.setContentHuggingPriority(.init(1), for: .vertical)
        for label in [status, controls] { label.setContentHuggingPriority(.required, for: .vertical) }
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [imageView, status, controls] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
        window.contentView = stack
        window.title = baseTitle
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        input.onChange = { [weak self] text in DispatchQueue.main.async { self?.inputText = text; self?.refreshControls() } }
        setUpControllers()
        setUpKeyboard()
        refreshControls()
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.input.poll() }
        Thread.detachNewThread { self.readLoop() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func windowDidResignKey(_ n: Notification) { imageView.release() }
    func windowWillClose(_ n: Notification) { imageView.release(); input.setPad(0) }

    func refreshControls() {
        let channel = input.enabled ? "input → melonDS CPU via \(ProcessInfo.processInfo.environment["NDS_VIEW_INPUT"]!)"
                                    : "input disabled (replay of a recorded trace)"
        controls.stringValue = "\(controllerText) | \(channel) | \(inputText)\n"
            + "pad: Nintendo layout (east=A south=B north=X west=Y), LB/LT=L RB/RT=R, Menu=Start Options=Select, d-pad/left stick | "
            + "keys: arrows, X=A Z=B S=X A=Y Q=L W=R Return=Start RShift=Select | mouse on bottom screen = touch"
    }

    // MARK: GameController

    func setUpControllers() {
        GCController.shouldMonitorBackgroundEvents = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.input.setPad(0)
            if let c = GCController.controllers().first { self.attach(c) }
            else { self.controllerText = "game controller disconnected"; self.refreshControls() }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    func attach(_ c: GCController) {
        let name = c.vendorName ?? c.productCategory
        guard let pad = c.extendedGamepad else {
            controllerText = "controller \(name): no extended gamepad profile (unsupported)"
            refreshControls(); return
        }
        controllerText = "controller: \(name) (\(c.productCategory)) connected"
        pad.valueChangedHandler = { [weak self] g, _ in self?.input.setPad(Self.mask(g)) }
        input.setPad(Self.mask(pad))
        refreshControls()
        NSLog("NdsView: attached controller %@ (%@)", name, c.productCategory)
    }

    static func mask(_ g: GCExtendedGamepad) -> UInt32 {
        var m: UInt32 = 0
        func set(_ k: Key, _ on: Bool) { if on { m |= 1 << UInt32(k.rawValue) } }
        set(.a, g.buttonB.isPressed); set(.b, g.buttonA.isPressed)
        set(.x, g.buttonY.isPressed); set(.y, g.buttonX.isPressed)
        set(.l, g.leftShoulder.isPressed || g.leftTrigger.isPressed)
        set(.r, g.rightShoulder.isPressed || g.rightTrigger.isPressed)
        set(.start, g.buttonMenu.isPressed); set(.select, g.buttonOptions?.isPressed ?? false)
        let s = g.leftThumbstick
        set(.up, g.dpad.up.isPressed || s.yAxis.value > 0.5)
        set(.down, g.dpad.down.isPressed || s.yAxis.value < -0.5)
        set(.left, g.dpad.left.isPressed || s.xAxis.value < -0.5)
        set(.right, g.dpad.right.isPressed || s.xAxis.value > 0.5)
        return m
    }

    // MARK: Keyboard (extra, never a substitute for the pad)

    func setUpKeyboard() {
        let map: [UInt16: Key] = [123: .left, 124: .right, 125: .down, 126: .up, 7: .a, 6: .b,
                                  1: .x, 0: .y, 12: .l, 13: .r, 36: .start]
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            if e.type == .flagsChanged, e.keyCode == 60 {
                self.input.setKeyboard(.select, e.modifierFlags.contains(.shift)); return nil
            }
            guard e.type != .flagsChanged, let k = map[e.keyCode] else { return e }
            if !e.isARepeat { self.input.setKeyboard(k, e.type == .keyDown) }
            return nil
        }
    }

    // MARK: Frame stream

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
        var frames = 0
        var last = "no frame was received"
        while let head = readExactly(headerSize) {
            let u = { (i: Int) in head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian } }
            if head.prefix(4) == Data("NDSE".utf8) {
                let text = readExactly(Int(u(8))).flatMap { String(data: $0, encoding: .utf8) } ?? "(unreadable message)"
                stopped(u(4) == 0 ? "renderer finished: \(text)" : "RENDERER ERROR: \(text)", last: last, error: u(4) != 0)
                return
            }
            guard head.prefix(4) == Data("NDSF".utf8) else { stopped("bad record magic from trace-view", last: last, error: true); return }
            let frame = u(4), matched = u(8), compared = u(12)
            guard let pixels = readExactly(frameBytes) else { stopped("truncated frame from trace-view", last: last, error: true); return }
            guard let cg = makeImage(pixels) else { stopped("could not build an image for frame \(frame)", last: last, error: true); return }
            frames += 1
            last = "last shown: trace frame \(frame) (#\(frames)) | lines equal to melonDS's own render: \(matched)/\(compared)"
            if let path = ProcessInfo.processInfo.environment["NDS_VIEW_SNAPSHOT"] {
                // The exact bitmap handed to the window, for inspection without screen capture.
                do {
                    guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                } catch { NSLog("NdsView: snapshot %@ failed: %@", path, "\(error)") }
            }
            let image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
            let text = last
            DispatchQueue.main.async {
                self.imageView.image = image
                self.status.stringValue = "LIVE (open loop) — " + text
                self.window.title = "\(baseTitle) — frame \(frame)"
            }
        }
        stopped("trace-view exited without a terminal record (see trace-view.log)", last: last, error: true)
    }

    /// The stream is over: keep the last actual frame, never mark it live.
    func stopped(_ why: String, last: String, error: Bool) {
        DispatchQueue.main.async {
            self.status.stringValue = "STOPPED, NOT LIVE — \(why) | \(last)"
            self.status.textColor = error ? .systemRed : .labelColor
            self.window.title = "\(baseTitle) — \(error ? "STOPPED (ERROR)" : "STOPPED")"
        }
    }

    func makeImage(_ data: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                   | CGImageAlphaInfo.noneSkipFirst.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return cg
    }
}
