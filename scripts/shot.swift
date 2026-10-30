// Offscreen screenshot of a page.
// Usage: shot <url> <out.png> <dark|light> [javascript to run before capture]
import Cocoa
import WebKit

let args = CommandLine.arguments
let url = URL(string: args[1])!, out = args[2], dark = args[3] == "dark"
let js = args.count > 4 ? args[4] : ""
let width: CGFloat = 1280

final class Shot: NSObject, WKNavigationDelegate {
    let win = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: width, height: 820), styleMask: [.borderless],
                       backing: .buffered, defer: false)
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 820))

    func start() {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = wv
        win.orderFrontRegardless()
        wv.navigationDelegate = self
        wv.load(URLRequest(url: url))
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        // Offscreen windows pause CSS transitions, so turn them off before capturing.
        let prep = "document.head.insertAdjacentHTML('beforeend','<style>*{transition:none!important;animation:none!important}</style>');"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            w.evaluateJavaScript(prep + (js.isEmpty ? "0" : js)) { _, err in
                if let err = err { print("js error: \(err)") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.capture() }
            }
        }
    }

    func capture() {
        wv.takeSnapshot(with: WKSnapshotConfiguration()) { img, err in
            guard let img = img, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { print("snapshot failed: \(String(describing: err))"); exit(1) }
            try! png.write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let shot = Shot()
shot.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { print("timeout"); exit(1) }
app.run()
