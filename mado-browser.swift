// mado-browser.swift
// WKWebView pixel plugin for Mado.
//
// Coordinate note: Mado sends PHYSICAL pixel dimensions/coordinates
// (already multiplied by MADO_SCALE). WKWebView uses CSS (logical) pixels.
// All incoming x/y are divided by `scale` before JS calls.
// Snapshot CGImages are at physical resolution on Retina — we use
// cgImage.width/height for the MADO frame dimensions.
//
// Nav bar: a position:fixed overlay injected via evaluateJavaScript after
// every page load. evaluateJavaScript bypasses page CSP, so it works
// everywhere. The URL bar receives key events through the standard
// document.activeElement path when focused.

import Foundation
import AppKit
import WebKit

// MARK: - Scale

let scale: CGFloat = CGFloat(
    ProcessInfo.processInfo.environment["MADO_SCALE"]
        .flatMap { Double($0) } ?? 2.0
)

// MARK: - Globals

let defaultURL = "https://duckduckgo.com"

var webView:   WKWebView!
var webWindow: NSWindow!

/// Current logical (CSS) dimensions.
var cssW: CGFloat = 800
var cssH: CGFloat = 600

var snapshotTimer:    Timer?
var navigationPending = false
var mouseIsDown       = false

let stdoutHandle = FileHandle.standardOutput

// MARK: - MADO frame writer

func writeFrame(width: Int, height: Int, rgba: Data) {
    var out = Data(capacity: 12 + rgba.count)
    out.append(contentsOf: [0x4D, 0x41, 0x44, 0x4F])
    var w = UInt32(width).littleEndian
    var h = UInt32(height).littleEndian
    out.append(Data(bytes: &w, count: 4))
    out.append(Data(bytes: &h, count: 4))
    out.append(rgba)
    stdoutHandle.write(out)
}

// MARK: - Snapshot

func takeSnapshot() {
    guard !navigationPending else { return }
    let cfg = WKSnapshotConfiguration()
    cfg.rect = CGRect(x: 0, y: 0, width: cssW, height: cssH)

    webView.takeSnapshot(with: cfg) { image, error in
        guard let img = image, error == nil,
              let cg  = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let pw = cg.width;  let ph = cg.height
        guard pw > 0 && ph > 0 else { return }

        let bpr = pw * 4
        var raw = Data(count: pw * ph * 4)
        raw.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            let cs  = CGColorSpaceCreateDeviceRGB()
            let bmi = CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue)
            guard let ctx = CGContext(data: base, width: pw, height: ph,
                                      bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: cs, bitmapInfo: bmi.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        }

        // Premultiplied → straight alpha
        raw.withUnsafeMutableBytes { ptr in
            guard let b = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = 0
            while i < pw * ph * 4 {
                let a = b[i+3]
                if a > 0 && a < 255 {
                    let af = CGFloat(a) / 255.0
                    b[i]   = UInt8(min(255, Int(CGFloat(b[i])   / af)))
                    b[i+1] = UInt8(min(255, Int(CGFloat(b[i+1]) / af)))
                    b[i+2] = UInt8(min(255, Int(CGFloat(b[i+2]) / af)))
                }
                i += 4
            }
        }

        writeFrame(width: pw, height: ph, rgba: raw)
    }
}

// MARK: - Resize

func resizeWebView(physW: CGFloat, physH: CGFloat) {
    cssW = max(1, physW / scale)
    cssH = max(1, physH / scale)
    DispatchQueue.main.async {
        let r = CGRect(x: 0, y: 0, width: cssW, height: cssH)
        webView.frame = r
        webWindow.setContentSize(NSSize(width: cssW, height: cssH))
        webView.needsLayout = true
    }
}

// MARK: - JS helpers

/// Encode a Swift String as a JSON string literal (with surrounding quotes).
func jsLiteral(_ s: String) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: [s]),
       let str  = String(data: data, encoding: .utf8),
       str.count >= 2 {
        // Strip surrounding [ ]
        return String(str.dropFirst().dropLast())
    }
    return "\"" + s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
        + "\""
}

func js(_ code: String) {
    webView.evaluateJavaScript(code, completionHandler: nil)
}

// MARK: - Nav bar injection
//
// A position:fixed overlay injected after every page load.
// evaluateJavaScript bypasses CSP, so this works on any site.
// The URL input receives key events via document.activeElement when focused.

let navBarCSS = """
#mado-nav {
  position: fixed;
  top: 0; left: 0; right: 0;
  height: 42px;
  background: #16161e;
  display: flex;
  align-items: center;
  padding: 0 8px;
  gap: 6px;
  z-index: 2147483647;
  box-sizing: border-box;
  font-family: -apple-system, BlinkMacSystemFont, sans-serif;
  border-bottom: 1px solid #2a2a3e;
}
#mado-url {
  flex: 1;
  background: #1e1e2e;
  color: #cdd6f4;
  border: 1px solid #45475a;
  border-radius: 6px;
  padding: 4px 10px;
  font-size: 13px;
  outline: none;
  min-width: 0;
}
#mado-url:focus { border-color: #89b4fa; }
#mado-nav button {
  background: #24243e;
  color: #cdd6f4;
  border: none;
  border-radius: 6px;
  padding: 4px 10px;
  font-size: 16px;
  cursor: pointer;
  flex-shrink: 0;
  line-height: 1;
}
#mado-nav button:hover { background: #313155; }
"""

let navBarJS = """
(function() {
  // Inject or re-use style
  var styleId = 'mado-nav-style';
  if (!document.getElementById(styleId)) {
    var st = document.createElement('style');
    st.id = styleId;
    st.textContent = `\(navBarCSS)`;
    document.head && document.head.appendChild(st);
  }

  // Remove any existing bar (handles re-injection after SPA navigation)
  var old = document.getElementById('mado-nav');
  if (old) old.remove();

  var nav = document.createElement('div');
  nav.id = 'mado-nav';

  var url = document.createElement('input');
  url.id = 'mado-url';
  url.type = 'text';
  url.autocomplete = 'off';
  url.spellcheck = false;
  url.value = location.href;

  var refresh = document.createElement('button');
  refresh.id = 'mado-refresh';
  refresh.textContent = '⟳';
  refresh.title = 'Reload';

  nav.appendChild(url);
  nav.appendChild(refresh);
  (document.body || document.documentElement).appendChild(nav);

  // Enter → navigate; Escape → blur
  url.addEventListener('keydown', function(e) {
    if (e.key === 'Enter') {
      var v = url.value.trim();
      if (!v.startsWith('http://') && !v.startsWith('https://')) {
        v = (v.indexOf('.') >= 0 && v.indexOf(' ') < 0)
          ? 'https://' + v
          : 'https://duckduckgo.com/?q=' + encodeURIComponent(v);
      }
      location.href = v;
    }
    if (e.key === 'Escape') { url.blur(); }
    e.stopPropagation();
  });

  // Prevent page from stealing focus-related keyboard events when URL bar is active
  url.addEventListener('keypress', function(e) { e.stopPropagation(); });

  refresh.addEventListener('click', function(e) {
    location.reload();
    e.stopPropagation();
  });
})();
"""

/// Call after every navigation to keep the displayed URL current.
func updateNavBarURL(_ urlStr: String) {
    let lit = jsLiteral(urlStr)
    js("var u=document.getElementById('mado-url');if(u&&u!==document.activeElement)u.value=\(lit);")
}

// MARK: - Cursor blink polyfill

let blinkPolyfill = """
(function(){
  if(window.__madoBlink)return;
  window.__madoBlink=true;
  var on=true;
  setInterval(function(){
    on=!on;
    var el=document.activeElement;
    if(!el)return;
    var t=el.tagName;
    if(t==='INPUT'||t==='TEXTAREA'||el.isContentEditable)
      el.style.caretColor=on?'':'transparent';
  },500);
})();
"""

// MARK: - Navigation delegate

class NavDelegate: NSObject, WKNavigationDelegate {
    func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
        navigationPending = false
        let url = wv.url?.absoluteString ?? ""
        wv.evaluateJavaScript(navBarJS, completionHandler: nil)
        wv.evaluateJavaScript(blinkPolyfill, completionHandler: nil)
        // Small delay so the bar is in the DOM before we update the URL text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { updateNavBarURL(url) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { takeSnapshot() }
    }
    func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        navigationPending = false
    }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError _: Error) {
        navigationPending = false
    }
}

// MARK: - Modifier-only filter

func isModifierOnly(_ text: String) -> Bool {
    guard text.count == 1, let s = text.unicodeScalars.first else { return false }
    return s.value >= 0x0010 && s.value <= 0x0019
}

// MARK: - Key handling

func handleKey(text: String, ctrl: Bool, meta: Bool, alt: Bool, shift: Bool) {
    guard !isModifierOnly(text) else { return }

    // ── Browser shortcuts (only when URL bar is NOT focused) ─────────────
    if meta || ctrl {
        switch text {
        case "r", "R":
            DispatchQueue.main.async { webView.reload() }; return
        case "a", "A":
            js("(function(){var el=document.activeElement;if(el&&(el.tagName==='INPUT'||el.tagName==='TEXTAREA')){el.select();}else{document.execCommand('selectAll');}})();"); return
        case "c", "C":
            js("document.execCommand('copy');"); return
        case "x", "X":
            js("document.execCommand('cut');"); return
        case "z", "Z":
            js(shift ? "document.execCommand('redo');" : "document.execCommand('undo');"); return
        case "v", "V":
            return  // handled via "paste" event
        default: break
        }
    }

    // ── Map Slint private codepoints → JS key names ───────────────────────
    var jsKey = text
    var keyCode = 0

    switch text {
    case "\u{F700}": jsKey = "ArrowUp";    keyCode = 38
    case "\u{F701}": jsKey = "ArrowDown";  keyCode = 40
    case "\u{F702}": jsKey = "ArrowLeft";  keyCode = 37
    case "\u{F703}": jsKey = "ArrowRight"; keyCode = 39
    case "\u{0008}": jsKey = "Backspace";  keyCode = 8
    case "\u{007F}": jsKey = "Backspace";  keyCode = 8
    case "\r", "\n": jsKey = "Enter";      keyCode = 13
    case "\t":       jsKey = "Tab";        keyCode = 9
    case "\u{001B}": jsKey = "Escape";     keyCode = 27
    case "\u{F729}": jsKey = "Home";       keyCode = 36
    case "\u{F72B}": jsKey = "End";        keyCode = 35
    case "\u{F72C}": jsKey = "PageUp";     keyCode = 33
    case "\u{F72D}": jsKey = "PageDown";   keyCode = 34
    case "\u{F728}": jsKey = "Delete";     keyCode = 46
    default:
        if let sc = text.unicodeScalars.first { keyCode = Int(sc.value) }
    }

    let insertable  = jsKey.count == 1 && !ctrl && !meta
    let ctrlStr  = ctrl  ? "true" : "false"
    let metaStr  = meta  ? "true" : "false"
    let altStr   = alt   ? "true" : "false"
    let shiftStr = shift ? "true" : "false"
    let keyLit   = jsLiteral(jsKey)
    let charLit  = jsLiteral(text)

    js("""
    (function(){
      var el=document.activeElement||document.body;
      var opts={bubbles:true,cancelable:true,
        key:\(keyLit),code:\(keyLit),keyCode:\(keyCode),which:\(keyCode),
        ctrlKey:\(ctrlStr),metaKey:\(metaStr),altKey:\(altStr),shiftKey:\(shiftStr)};
      el.dispatchEvent(new KeyboardEvent('keydown',opts));
      el.dispatchEvent(new KeyboardEvent('keypress',opts));
      el.dispatchEvent(new KeyboardEvent('keyup',opts));
      var isInput=(el.tagName==='INPUT'||el.tagName==='TEXTAREA');
      if(\(keyLit)==='Backspace'){
        if(isInput){
          var s=el.selectionStart,e=el.selectionEnd;
          if(s!==e){el.value=el.value.substring(0,s)+el.value.substring(e);el.selectionStart=el.selectionEnd=s;}
          else if(s>0){el.value=el.value.substring(0,s-1)+el.value.substring(s);el.selectionStart=el.selectionEnd=s-1;}
          el.dispatchEvent(new Event('input',{bubbles:true}));
        }else if(el.isContentEditable){document.execCommand('delete');}
        return;
      }
      if(\(keyLit)==='Delete'){
        if(isInput){
          var s=el.selectionStart,e=el.selectionEnd;
          if(s!==e){el.value=el.value.substring(0,s)+el.value.substring(e);el.selectionStart=el.selectionEnd=s;}
          else if(s<el.value.length){el.value=el.value.substring(0,s)+el.value.substring(s+1);el.selectionStart=el.selectionEnd=s;}
          el.dispatchEvent(new Event('input',{bubbles:true}));
        }else if(el.isContentEditable){document.execCommand('forwardDelete');}
        return;
      }
      if(\(insertable ? "true" : "false")){
        var ch=\(charLit);
        if(isInput){
          var s=el.selectionStart,e=el.selectionEnd;
          el.value=el.value.substring(0,s)+ch+el.value.substring(e);
          el.selectionStart=el.selectionEnd=s+ch.length;
          el.dispatchEvent(new Event('input',{bubbles:true}));
        }else if(el.isContentEditable){document.execCommand('insertText',false,ch);}
      }
    })();
    """)
}

// MARK: - Event processor

class EventProcessor {
    func processLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type_ = json["type"] as? String else { return }

        switch type_ {

        case "resize":
            let w = json["width"]  as? CGFloat ?? cssW * scale
            let h = json["height"] as? CGFloat ?? cssH * scale
            resizeWebView(physW: w, physH: h)

        case "key":
            let text  = json["text"]  as? String ?? ""
            let ctrl  = json["ctrl"]  as? Bool   ?? false
            let meta  = json["meta"]  as? Bool   ?? false
            let alt   = json["alt"]   as? Bool   ?? false
            let shift = json["shift"] as? Bool   ?? false
            DispatchQueue.main.async { handleKey(text: text, ctrl: ctrl, meta: meta, alt: alt, shift: shift) }

        case "mouse_press":
            let px = (json["x"] as? CGFloat ?? 0) / scale
            let py = (json["y"] as? CGFloat ?? 0) / scale
            mouseIsDown = true
            DispatchQueue.main.async {
                js("""
                (function(){
                  var el=document.elementFromPoint(\(px),\(py));
                  if(!el)return;
                  el.dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,buttons:1,clientX:\(px),clientY:\(py)}));
                  el.dispatchEvent(new MouseEvent('mouseup',  {bubbles:true,cancelable:true,clientX:\(px),clientY:\(py)}));
                  el.dispatchEvent(new MouseEvent('click',    {bubbles:true,cancelable:true,clientX:\(px),clientY:\(py)}));
                  var t=el.tagName;
                  if(t==='INPUT'||t==='TEXTAREA'||el.isContentEditable){
                    el.focus();
                    window.__madoFocused=el;
                  }
                })();
                """)
            }

        case "mouse_move":
            guard mouseIsDown else { break }
            let px = (json["x"] as? CGFloat ?? 0) / scale
            let py = (json["y"] as? CGFloat ?? 0) / scale
            DispatchQueue.main.async {
                js("document.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,cancelable:true,buttons:1,clientX:\(px),clientY:\(py)}));")
            }

        case "mouse_release":
            mouseIsDown = false
            DispatchQueue.main.async {
                js("document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true,cancelable:true}));")
            }

        case "scroll":
            let delta = json["delta"] as? CGFloat ?? 0
            DispatchQueue.main.async { js("window.scrollBy(0,\(-delta * 3));") }

        case "paste":
            if let text = json["text"] as? String {
                let lit = jsLiteral(text)
                DispatchQueue.main.async {
                    js("""
                    (function(){
                      var t=\(lit);
                      var el=document.activeElement;
                      if(!el)return;
                      if(el.tagName==='INPUT'||el.tagName==='TEXTAREA'){
                        var s=el.selectionStart,e=el.selectionEnd;
                        el.value=el.value.substring(0,s)+t+el.value.substring(e);
                        el.selectionStart=el.selectionEnd=s+t.length;
                        el.dispatchEvent(new Event('input',{bubbles:true}));
                      }else if(el.isContentEditable){document.execCommand('insertText',false,t);}
                    })();
                    """)
                }
            }

        case "navigate":
            if let urlStr = json["url"] as? String, let url = URL(string: urlStr) {
                DispatchQueue.main.async { navigationPending = true; webView.load(URLRequest(url: url)) }
            }

        case "focus":
            DispatchQueue.main.async {
                webWindow.makeFirstResponder(webView)
                js("if(window.__madoFocused)window.__madoFocused.focus();")
            }

        case "blur":
            break

        default: break
        }
    }
}

// MARK: - App setup

let navDelegate = NavDelegate()

class AppDelegate: NSObject, NSApplicationDelegate {
    let events = EventProcessor()

    func applicationDidFinishLaunching(_: Notification) {
        webWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: cssW, height: cssH),
            styleMask: [.borderless], backing: .buffered, defer: false)
        webWindow.isReleasedWhenClosed = false
        webWindow.level = .screenSaver

        let cfg = WKWebViewConfiguration()
        if #available(macOS 10.12, *) { cfg.mediaTypesRequiringUserActionForPlayback = [] }

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: cssW, height: cssH), configuration: cfg)
        webView.navigationDelegate = navDelegate
        webWindow.contentView = webView
        webWindow.makeKeyAndOrderFront(nil)
        webWindow.makeFirstResponder(webView)
        webWindow.setFrameOrigin(NSPoint(x: -10000, y: -10000))

        if let url = URL(string: defaultURL) {
            navigationPending = true
            webView.load(URLRequest(url: url))
        }

        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 1.0/10.0, repeats: true) { _ in
            takeSnapshot()
        }

        DispatchQueue.global(qos: .background).async {
            let stdin = FileHandle.standardInput
            var buf = ""
            while true {
                let chunk = stdin.availableData
                if chunk.isEmpty { DispatchQueue.main.async { NSApp.terminate(nil) }; return }
                guard let s = String(data: chunk, encoding: .utf8) else { continue }
                buf += s
                while let nl = buf.range(of: "\n") {
                    let line = String(buf[buf.startIndex..<nl.lowerBound])
                    buf.removeSubrange(buf.startIndex...nl.lowerBound)
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    DispatchQueue.main.async { self.events.processLine(trimmed) }
                }
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
