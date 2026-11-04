import SwiftUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

@main
struct CineCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct ContentView: View {
    @StateObject private var cam = CameraModel()
    @State private var showPicker = false
    @State private var showGamma = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PreviewView(session: cam.session).ignoresSafeArea()

            // ปุ่มเพิ่มเสียง = ไฟฉาย / ปุ่มลดเสียง = อัด-หยุด (ตรวจสลับได้ถ้าเครื่องจริงกลับกัน)
            ButtonCatcher(primary: { cam.toggleTorch() },
                          secondary: { cam.toggleRecording() })
                .frame(width: 1, height: 1)

            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    torchButton
                    Spacer()
                    statusBar
                    Spacer()
                    torchButton
                }
                Spacer()
                if showGamma { gammaPanel }

                // สไลด์ซูมโชว์เสมอ
                VStack(spacing: 2) {
                    Text(String(format: "%.1f×", cam.zoom)).font(.caption).foregroundColor(.white)
                    Slider(value: $cam.zoom, in: 1...8)
                        .onChange(of: cam.zoom) { _, _ in cam.applyZoom() }
                }

                HStack(alignment: .center) {
                    VStack(spacing: 10) {
                        Button { showGamma.toggle() } label: {
                            Text("Γ").font(.title3.bold()).frame(width: 52, height: 52)
                                .background(showGamma ? Color.white : Color.white.opacity(0.25))
                                .foregroundColor(showGamma ? .black : .white)
                                .clipShape(Circle())
                        }
                        // AF/MF ล่างซ้าย
                        Button { cam.manualFocus.toggle(); cam.applyFocus() } label: {
                            Text(cam.manualFocus ? "MF" : "AF")
                                .font(.headline).frame(width: 52, height: 52)
                                .background(cam.manualFocus ? Color.yellow : Color.white.opacity(0.25))
                                .foregroundColor(cam.manualFocus ? .black : .white)
                                .clipShape(Circle())
                        }
                    }
                    Spacer()
                    recordButton
                    Spacer()
                    Picker("Lens", selection: $cam.lens) {
                        ForEach(CameraModel.Lens.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 150)
                    .onChange(of: cam.lens) { _, new in cam.switchLens(new) }
                }
            }
            .padding()

            // โฟกัสแมนนวล: แสดงสไลเดอร์ซ้ายและขวาของจอ
            if cam.manualFocus {
                HStack {
                    focusSlider.padding(.leading, 8)
                    Spacer()
                    focusSlider.padding(.trailing, 8)
                }
            }
        }
        .onAppear { cam.start() }
        .sheet(isPresented: $showPicker) { FolderPicker { cam.setFolder($0) } }
    }

    private var recordButton: some View {
        Button { cam.toggleRecording() } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                RoundedRectangle(cornerRadius: cam.isRecording ? 6 : 30)
                    .fill(Color.red)
                    .frame(width: cam.isRecording ? 30 : 58, height: cam.isRecording ? 30 : 58)
            }
        }
    }

    private var torchButton: some View {
        Button { cam.toggleTorch() } label: {
            Image(systemName: cam.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                .font(.title2).frame(width: 48, height: 48)
                .background(cam.torchOn ? Color.yellow : Color.white.opacity(0.25))
                .foregroundColor(cam.torchOn ? .black : .white)
                .clipShape(Circle())
        }
    }

    private var statusBar: some View {
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Text("🔋 \(cam.batteryPercent)%")
                Text("💾 \(Int(cam.freeGB)) GB")
                if cam.isRecording { Text("● REC").foregroundColor(.red) }
            }
            .font(.footnote.monospacedDigit()).foregroundColor(.white)
            Button { showPicker = true } label: {
                Text("📁 \(cam.folderName)").font(.caption).lineLimit(1).foregroundColor(.white)
            }
            if !cam.message.isEmpty {
                Text(cam.message).font(.caption).foregroundColor(.yellow).lineLimit(2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.black.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var gammaPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Gamma.allCases) { g in
                    Button { cam.gamma = g; cam.applyLook() } label: {
                        Text(g.rawValue).font(.footnote.bold())
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(cam.gamma == g ? Color.white : Color.white.opacity(0.2))
                            .foregroundColor(cam.gamma == g ? .black : .white)
                            .clipShape(Capsule())
                    }
                }
            }
            labeled("Shadow", $cam.shadow, -1...1)
            labeled("Highlight", $cam.highlight, -1...1)
            labeled("Saturation", $cam.saturation, 0.5...1.5)
        }
        .padding(12).frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.65)).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func labeled(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(name).font(.caption).foregroundColor(.white).frame(width: 74, alignment: .leading)
            Slider(value: value, in: range).onChange(of: value.wrappedValue) { _, _ in cam.applyLook() }
            Text(String(format: "%+.2f", value.wrappedValue)).font(.caption.monospacedDigit())
                .foregroundColor(.white).frame(width: 44)
        }
    }

    private var focusSlider: some View {
        Slider(value: $cam.focusValue, in: 0...1)
            .frame(width: 260)
            .rotationEffect(.degrees(-90))
            .frame(width: 44, height: 260)
            .onChange(of: cam.focusValue) { _, _ in cam.applyFocus() }
    }
}

// MARK: Preview layer
struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.connection?.videoRotationAngle = 90   // portrait
    }
}

// MARK: ปุ่มเพิ่ม/ลดเสียง (iOS 17.2+)
struct ButtonCatcher: UIViewRepresentable {
    var primary: () -> Void
    var secondary: () -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        let i = AVCaptureEventInteraction(
        let i = AVCaptureEventInteraction(
            primary: { e in if e.phase == .began { primary() } },
            secondary: { e in if e.phase == .began { secondary() } })
        i.isEnabled = true
        v.addInteraction(i)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: เลือกโฟลเดอร์
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(_ onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first { onPick(u) }
        }
    }
}
