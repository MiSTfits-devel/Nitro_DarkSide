// nds-view entry point; the window, input and stream code is in NdsView.swift.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
