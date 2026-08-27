import CoreGraphics
import Foundation
// A click as a hand makes it: a real HID event source (a nil source lacks
// the fields some hosts check), the pointer moved to the spot and left
// there a moment so the view sees it enter, click state set, a press that
// lasts. Screen coordinates.
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let src = CGEventSource(stateID: .hidSystemState)
func post(_ t: CGEventType, _ pt: CGPoint, clicks: Int64 = 0) {
  let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: pt, mouseButton: .left)!
  if clicks > 0 { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
  e.post(tap: .cghidEventTap)
}
post(.mouseMoved, CGPoint(x: p.x - 8, y: p.y - 8))
usleep(40000)
post(.mouseMoved, p)
usleep(150000)
post(.leftMouseDown, p, clicks: 1)
usleep(90000)
post(.leftMouseUp, p, clicks: 1)
