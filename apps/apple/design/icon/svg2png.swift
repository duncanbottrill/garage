import Cocoa
import WebKit
// usage: svg2png <svg path> <px> <out.png>   (transparent background preserved)
let a = CommandLine.arguments
let src = URL(fileURLWithPath: a[1]), px = Double(a[2])!, out = a[3]; let opaque = a.count > 4 && a[4] == "--opaque"
let app = NSApplication.shared
let pts = 512.0
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: pts, height: pts))
web.setValue(false, forKey: "drawsBackground")
let win = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
win.isOpaque = false; win.backgroundColor = .clear; win.contentView = web
class D: NSObject, WKNavigationDelegate {
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      let c = WKSnapshotConfiguration(); c.snapshotWidth = NSNumber(value: px / (NSScreen.main?.backingScaleFactor ?? 2))
      w.takeSnapshot(with: c) { img, err in
        guard let img = img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("fail \(String(describing: err))"); exit(1) }
        var rep = NSBitmapImageRep(cgImage: cg)
        if opaque {
          let w = cg.width, h = cg.height
          let o = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
          let ctx = NSGraphicsContext(bitmapImageRep: o)!; NSGraphicsContext.current = ctx
          NSColor.black.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
          ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)); ctx.flushGraphics(); rep = o
        }
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print("\(out) \(rep.pixelsWide)x\(rep.pixelsHigh) alpha=\(rep.hasAlpha)"); exit(0)
      }
    }
  }
}
let d = D(); web.navigationDelegate = d
let svg = try! String(contentsOf: src, encoding: .utf8)
let html = "<!doctype html><html><head><meta charset='utf-8'><style>html,body{margin:0;background:transparent}svg{display:block;width:\(pts)px;height:\(pts)px}</style></head><body>\(svg)</body></html>"
web.loadHTMLString(html, baseURL: nil)
app.run()
