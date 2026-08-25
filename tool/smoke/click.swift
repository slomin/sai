import CoreGraphics
import Foundation
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
for (t, b) in [(CGEventType.mouseMoved, CGMouseButton.left), (.leftMouseDown, .left), (.leftMouseUp, .left)] {
  let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b)!
  e.post(tap: .cghidEventTap)
  usleep(60000)
}
