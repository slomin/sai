import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "sai" && (w["kCGWindowLayer"] as? Int) == 0 {
  print(w["kCGWindowNumber"] as! Int); break
}
