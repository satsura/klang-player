import AppKit
import CoreImage.CIFilterBuiltins

/// Phone remote: a small web page served by the app on the home network.
/// Off by default; works only with the secret key in the link.
enum Remote {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.bool(forKey: "remoteEnabled") }
        set {
            d.set(newValue, forKey: "remoteEnabled")
            FileServer.shared.remoteKey = newValue ? key : nil
        }
    }

    static var key: String {
        if let k = d.string(forKey: "remoteKey"), !k.isEmpty { return k }
        return regenerate()
    }

    /// New secret key; old links stop working.
    @discardableResult
    static func regenerate() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let k = bytes.map { String(format: "%02x", $0) }.joined()
        d.set(k, forKey: "remoteKey")
        if enabled { FileServer.shared.remoteKey = k }
        return k
    }

    static var url: String? {
        let target = Config.speakerIP.isEmpty ? "192.168.1.1" : Config.speakerIP
        guard let ip = localIP(toward: target), FileServer.shared.port != 0 else { return nil }
        return "http://\(ip):\(FileServer.shared.port)/remote?k=\(key)"
    }

    static func qrCode(_ text: String, size: CGFloat = 160) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let ci = f.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: size / ci.extent.width, y: size / ci.extent.height))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }

    static var page: String {
        let nothing = String(localized: "Nothing playing")
        let offline = String(localized: "No connection to the Mac")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta name="apple-mobile-web-app-capable" content="yes"><title>Klang Player</title>
        <style>
        :root{color-scheme:dark}
        body{margin:0;font-family:-apple-system,system-ui,sans-serif;background:#111;color:#fff;
             padding:max(20px,env(safe-area-inset-top)) 20px max(24px,env(safe-area-inset-bottom));
             display:flex;flex-direction:column;align-items:center;min-height:100vh;box-sizing:border-box}
        #bg{position:fixed;inset:0;background-size:cover;background-position:center;filter:blur(50px) brightness(.45);transform:scale(1.2);z-index:-1}
        #cover{width:min(78vw,360px);aspect-ratio:1;border-radius:14px;background:#2a2a2a center/cover;box-shadow:0 12px 40px #0009;margin-top:12px}
        h1{font-size:21px;margin:22px 0 4px;text-align:center}
        #artist{opacity:.7;font-size:15px;text-align:center;min-height:1.2em}
        .row{width:min(86vw,380px);display:flex;align-items:center;gap:10px}
        input[type=range]{flex:1;accent-color:#fff}
        .times{width:min(86vw,380px);display:flex;justify-content:space-between;font-size:12px;opacity:.6;font-variant-numeric:tabular-nums}
        .controls{display:flex;gap:44px;align-items:center;margin:18px 0 26px}
        button{background:none;border:0;color:#fff;padding:6px;-webkit-tap-highlight-color:transparent}
        button svg{display:block;fill:#fff}
        #status{font-size:12px;opacity:.6;margin-top:16px;min-height:1em}
        </style></head><body><div id="bg"></div>
        <div id="cover"></div><h1 id="title">\(nothing)</h1><div id="artist"></div>
        <div class="row" style="margin-top:22px"><input id="pos" type="range" min="0" max="1" step="1" value="0"></div>
        <div class="times"><span id="t1">0:00</span><span id="t2">0:00</span></div>
        <div class="controls">
          <button id="prev"><svg width="34" height="34" viewBox="0 0 24 24"><path d="M6 6h2v12H6zm3.5 6 8.5 6V6z"/></svg></button>
          <button id="play"><svg id="pi" width="64" height="64" viewBox="0 0 24 24"></svg></button>
          <button id="next"><svg width="34" height="34" viewBox="0 0 24 24"><path d="M16 6h2v12h-2zM6 18l8.5-6L6 6z"/></svg></button>
        </div>
        <div class="row"><svg width="18" height="18" viewBox="0 0 24 24" style="fill:#fff;opacity:.6"><path d="M3 9v6h4l5 5V4L7 9H3z"/></svg>
          <input id="vol" type="range" min="0" max="32" step="1" value="0">
          <svg width="22" height="22" viewBox="0 0 24 24" style="fill:#fff;opacity:.6"><path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3A4.5 4.5 0 0 0 14 8v8a4.5 4.5 0 0 0 2.5-4zM14 3.2v2.1a7 7 0 0 1 0 13.4v2.1a9 9 0 0 0 0-17.6z"/></svg></div>
        <div id="status"></div>
        <script>
        const k=new URLSearchParams(location.search).get('k');
        const q=(p,x)=>`/api/${p}?k=${encodeURIComponent(k)}${x||''}`;
        const post=(p,x)=>fetch(q(p,x),{method:'POST'}).then(tick);
        const $=id=>document.getElementById(id);
        const PLAY='<path d="M8 5v14l11-7z"/>',PAUSE='<path d="M6 5h4v14H6zm8 0h4v14h-4z"/>';
        const fmt=s=>{s=Math.max(0,Math.floor(s));return Math.floor(s/60)+':'+String(s%60).padStart(2,'0')};
        let art='',seeking=false,voling=false;
        async function tick(){
          try{
            const s=await (await fetch(q('state'))).json();
            $('title').textContent=s.title||'\(nothing)';
            $('artist').textContent=[s.artist,s.album].filter(Boolean).join(' — ');
            $('pi').innerHTML=(s.state==='playing'||s.state==='preparing')?PAUSE:PLAY;
            if(!seeking){$('pos').max=Math.max(1,Math.round(s.duration));$('pos').value=Math.round(s.position)}
            $('t1').textContent=fmt(s.position);$('t2').textContent='-'+fmt(s.duration-s.position);
            if(!voling){$('vol').max=s.maxVolume;$('vol').value=s.volume}
            $('next').style.opacity=s.hasNext?1:.35;
            if(s.artId!==art){art=s.artId;const u=art?`url("${q('art','&t='+art)}")`:'';$('cover').style.backgroundImage=u;$('bg').style.backgroundImage=u}
            $('status').textContent='';
          }catch(e){$('status').textContent='\(offline)'}
        }
        $('play').onclick=()=>post('toggle');$('next').onclick=()=>post('next');$('prev').onclick=()=>post('prev');
        $('pos').oninput=()=>{seeking=true;$('t1').textContent=fmt($('pos').value)};
        $('pos').onchange=()=>{post('seek','&v='+$('pos').value);seeking=false};
        $('vol').oninput=()=>{voling=true};
        $('vol').onchange=()=>{post('volume','&v='+$('vol').value);setTimeout(()=>voling=false,1500)};
        tick();setInterval(tick,1500);
        </script></body></html>
        """
    }
}
