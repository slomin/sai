import CoreGraphics
import Foundation
// drag x1 y1 x2 y2: press at the first point, move to the second in
// steps a real hand would take, release. Screen coordinates.
let a = CommandLine.arguments
let from = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let to = CGPoint(x: Double(a[3])!, y: Double(a[4])!)
func post(_ t: CGEventType, _ p: CGPoint) {
  CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
    .post(tap: .cghidEventTap)
}
post(.mouseMoved, from)
usleep(80000)
post(.leftMouseDown, from)
usleep(120000)
let steps = 24
for i in 1...steps {
  let f = Double(i) / Double(steps)
  post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * f, y: from.y + (to.y - from.y) * f))
  usleep(25000)
}
usleep(120000)
post(.leftMouseUp, to)
