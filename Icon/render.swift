// Renders the app icon variants: swift Icon/render.swift <out-dir>
import AppKit
import SwiftUI

let C: CGFloat = 1024            // canvas
let S: CGFloat = 824             // squircle (macOS icon grid)
let R: CGFloat = 185

func hex(_ h: UInt32) -> Color {
    Color(red: Double((h >> 16) & 0xff) / 255, green: Double((h >> 8) & 0xff) / 255, blue: Double(h & 0xff) / 255)
}

struct Base<Content: View>: View {
    let bg: [Color]
    @ViewBuilder let content: Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: R, style: .continuous)
                .fill(LinearGradient(colors: bg, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: R, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center))
                )
                .overlay(content.frame(width: S, height: S).clipShape(RoundedRectangle(cornerRadius: R, style: .continuous)))
                .frame(width: S, height: S)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 10)
        }
        .frame(width: C, height: C)
    }
}

/// Arc from a centre, used for sound waves.
struct Arc: Shape {
    let radius: CGFloat
    let span: Double
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: radius,
                 startAngle: .degrees(-span / 2), endAngle: .degrees(span / 2), clockwise: false)
        return p
    }
}

// A: speaker cone + sound waves
struct IconA: View {
    var body: some View {
        Base(bg: [hex(0x3A2F8F), hex(0x7B3FB0), hex(0xD9467E)]) {
            ZStack {
                ZStack {
                    Circle().fill(.white).frame(width: 330)
                    Circle().fill(LinearGradient(colors: [hex(0x4A3A9E), hex(0x2A1F66)], startPoint: .top, endPoint: .bottom)).frame(width: 270)
                    Circle().stroke(.white.opacity(0.25), lineWidth: 6).frame(width: 200)
                    Circle().fill(LinearGradient(colors: [.white, hex(0xD8D0F5)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 96)
                }
                .offset(x: -120)
                ForEach(0..<3) { i in
                    Arc(radius: CGFloat(230 + i * 70), span: 64)
                        .stroke(.white.opacity(1 - Double(i) * 0.28), style: StrokeStyle(lineWidth: 34, lineCap: .round))
                        .offset(x: -120)
                }
            }
        }
    }
}

// B: disc with a waveform
struct IconB: View {
    let bars: [CGFloat] = [0.25, 0.45, 0.7, 0.4, 0.9, 1.0, 0.65, 0.85, 0.5, 0.3, 0.55, 0.2]
    var body: some View {
        Base(bg: [hex(0x1B1F2E), hex(0x10131C)]) {
            ZStack {
                Circle().fill(AngularGradient(colors: [hex(0xFF8A3D), hex(0xFF3D7F), hex(0x8F5BFF), hex(0xFF8A3D)], center: .center))
                    .frame(width: 600)
                Circle().fill(hex(0x141824)).frame(width: 540)
                HStack(spacing: 18) {
                    ForEach(bars.indices, id: \.self) { i in
                        Capsule().fill(LinearGradient(colors: [hex(0xFFB36B), hex(0xFF4F8B)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 22, height: 300 * bars[i])
                    }
                }
            }
        }
    }
}

// C: the letter K — a bar with sound waves for its arms
struct IconC: View {
    var body: some View {
        Base(bg: [hex(0x0F9D8F), hex(0x1867C0), hex(0x23338C)]) {
            ZStack {
                Capsule().fill(.white).frame(width: 74, height: 440).offset(x: -150)
                ForEach(0..<3) { i in
                    Arc(radius: CGFloat(110 + i * 85), span: 100)
                        .stroke(.white.opacity(1 - Double(i) * 0.22), style: StrokeStyle(lineWidth: 52, lineCap: .round))
                        .offset(x: -150)
                }
            }
        }
    }
}

@MainActor func save<V: View>(_ v: V, _ path: String) {
    let r = ImageRenderer(content: v)
    r.scale = 1
    guard let img = r.cgImage else { fatalError("render") }
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
MainActor.assumeIsolated {
    save(IconA(), out + "/icon-a.png")
    save(IconB(), out + "/icon-b.png")
    save(IconC(), out + "/icon-c.png")
}
