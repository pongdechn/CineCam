import AVFoundation
import CoreImage
import Metal
import UIKit
import VideoToolbox

enum Gamma: String, CaseIterable, Identifiable {
    case natural = "Natural", dynamic = "Dynamic", flat = "Flat", logV2 = "Log V2"
    var id: String { rawValue }
}

struct Look {
    var gamma: Gamma = .logV2
    var shadow: Float = 0       // -1...1
    var highlight: Float = 0    // -1...1
    var saturation: Float = 0.9 // 0.5...1.5
}

final class CameraModel: NSObject, ObservableObject {

    enum Lens: String, CaseIterable, Identifiable {
        case ultraWide = "UW", wide = "Wide", tele = "Tele"
        var id: String { rawValue }
        var type: AVCaptureDevice.DeviceType {
            switch self {
            case .ultraWide: return .builtInUltraWideCamera
            case .wide: return .builtInWideAngleCamera
            case .tele: return .builtInTelephotoCamera
            }
        }
    }

    // MARK: UI state
    @Published var isRecording = false
    @Published var torchOn = false
    @Published var zoom: Double = 1
    @Published var lens: Lens = .wide
    @Published var manualFocus = false
    @Published var focusValue: Double = 0.5
    @Published var batteryPercent = 0
    @Published var freeGB = 0.0
    @Published var folderName = "ยังไม่ได้เลือกโฟลเดอร์"
    @Published var message = ""
    @Published var gamma: Gamma = .logV2
    @Published var shadow: Double = 0
    @Published var highlight: Double = 0
    @Published var saturation: Double = 0.9

    // MARK: Capture
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "cam.session")
    private let videoQueue = DispatchQueue(label: "cam.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "cam.audio")
    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?

    // MARK: Writer (guarded by lock)
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var vInput: AVAssetWriterInput?
    private var aInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var recordingFolder: URL?

    // MARK: Look / Gamma (8-bit, software)
    private let ciContext = CIContext(
        mtlDevice: MTLCreateSystemDefaultDevice()!,
        options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private var cube: CIFilter = CameraModel.makeCube(Look())
    private let lookQueue = DispatchQueue(label: "cam.look")

    func applyLook() {
        let look = Look(gamma: gamma, shadow: Float(shadow),
                        highlight: Float(highlight), saturation: Float(saturation))
        lookQueue.async {
            let f = CameraModel.makeCube(look)
            self.lock.lock(); self.cube = f; self.lock.unlock()
        }
    }

    // เส้นโค้งโดยประมาณให้ใกล้ลุคของ Filmic (ปรับตัวเลขได้)
    private static func curve(_ v: Float, _ look: Look) -> Float {
        var y: Float
        switch look.gamma {
        case .natural:
            y = v
        case .dynamic:
            let s = v * v * (3 - 2 * v)
            y = 0.6 * v + 0.4 * s
        case .flat:
            y = pow(v, 0.75)
        case .logV2:
            let a: Float = 40                      // ยิ่งมาก ภาพยิ่งแบน
            y = log2(pow(v, 2.4) * a + 1) / log2(a + 1)
        }
        y += look.shadow * 0.12 * (1 - y) * (1 - y)
        y += look.highlight * 0.12 * y * y
        return min(max(y, 0), 1)
    }

    private static func makeCube(_ look: Look) -> CIFilter {
        let n = 64
        var data = [Float]()
        data.reserveCapacity(n * n * n * 4)
        let lut: [Float] = (0..<n).map { curve(Float($0) / Float(n - 1), look) }
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            var c = [lut[r], lut[g], lut[b]]
            let y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
            for i in 0..<3 { c[i] = min(max(y + (c[i] - y) * look.saturation, 0), 1) }
            data += [c[0], c[1], c[2], 1]
        }}}
        let f = CIFilter(name: "CIColorCube")!
        f.setValue(n, forKey: "inputCubeDimension")
        f.setValue(data.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: "inputCubeData")
        return f
    }

    // MARK: Init
    override init() {
        super.init()
        UIDevice.current.isBatteryMonitoringEnabled = true
        if let url = resolveFolder() { folderName = url.lastPathComponent }
        refreshStatus()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    private func refreshStatus() {
        batteryPercent = max(0, Int(UIDevice.current.batteryLevel * 100))
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeGB = Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000
    }

    // MARK: Session
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.configureSession() }
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        configureDevice(for: .wide)

        if let mic = AVCaptureDevice.default(for: .audio),
           let mi = try? AVCaptureDeviceInput(device: mic), session.canAddInput(mi) {
            session.addInput(mi)
        }
        videoOut.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOut.alwaysDiscardsLateVideoFrames = false
        videoOut.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOut) { session.addOutput(videoOut) }
        audioOut.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOut) { session.addOutput(audioOut) }
        session.commitConfiguration()
        applyRotation()
        session.startRunning()
    }

    // แนวตั้ง: หมุนเฟรมจากเซนเซอร์ 90° ให้ได้ภาพ 2160x3840
    private func applyRotation() {
        if let c = videoOut.connection(with: .video), c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90
        }
    }

    private func best4K60(_ d: AVCaptureDevice) -> AVCaptureDevice.Format? {
        d.formats.last { f in
            let desc = f.formatDescription
            let dim = CMVideoFormatDescriptionGetDimensions(desc)
            return dim.width == 3840 && dim.height == 2160
                && CMFormatDescriptionGetMediaSubType(desc) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }
    }

    // เรียกภายใน begin/commitConfiguration เท่านั้น
    private func configureDevice(for lens: Lens) {
        guard let d = AVCaptureDevice.default(lens.type, for: .video, position: .back),
              let fmt = best4K60(d) else {
            DispatchQueue.main.async { self.message = "เลนส์นี้ไม่รองรับ 4K60 8-bit" }
            return
        }
        if let old = videoInput { session.removeInput(old) }
        do {
            let input = try AVCaptureDeviceInput(device: d)
            guard session.canAddInput(input) else { return }
            session.addInput(input)
            videoInput = input
            device = d
            try d.lockForConfiguration()
            d.activeFormat = fmt
            d.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
            d.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
            if fmt.isVideoHDRSupported {
                d.automaticallyAdjustsVideoHDREnabled = false
                d.isVideoHDREnabled = false
            }
            d.videoZoomFactor = 1
            d.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.message = "ตั้งค่ากล้องไม่ได้: \(error.localizedDescription)" }
        }
    }

    // MARK: Controls
    func switchLens(_ l: Lens) {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.configureDevice(for: l)
            self.session.commitConfiguration()
            self.applyRotation()
            DispatchQueue.main.async { self.zoom = 1; self.torchOn = false }
        }
    }

    func applyZoom() {
        let z = zoom
        sessionQueue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration()
            d.videoZoomFactor = min(max(z, 1), d.activeFormat.videoMaxZoomFactor)
            d.unlockForConfiguration()
        }
    }

    func toggleTorch() {
        let want = !torchOn
        sessionQueue.async {
            guard let d = self.device, d.hasTorch else {
                DispatchQueue.main.async { self.message = "เลนส์นี้ไม่มีไฟฉาย" }
                return
            }
            try? d.lockForConfiguration()
            if want { try? d.setTorchModeOn(level: 1.0) } else { d.torchMode = .off }
            d.unlockForConfiguration()
            DispatchQueue.main.async { self.torchOn = want }
        }
    }

    func applyFocus() {
        let manual = manualFocus
        let pos = Float(focusValue)
        sessionQueue.async {
            guard let d = self.device else { return }
            try? d.lockForConfiguration()
            if manual, d.isFocusModeSupported(.locked) {
                d.setFocusModeLocked(lensPosition: pos, completionHandler: nil)
            } else if d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
            }
            d.unlockForConfiguration()
        }
    }

    // MARK: Folder (ไม่เซฟลงแอป)
    func setFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            message = "เข้าถึงโฟลเดอร์ไม่ได้"; return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        if let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "folderBookmark")
            folderName = url.lastPathComponent
        }
    }

    private func resolveFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "folderBookmark") else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    // MARK: Recording
    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    private func startRecording() {
        guard let folder = resolveFolder(), folder.startAccessingSecurityScopedResource() else {
            message = "เลือกโฟลเดอร์บันทึกก่อน"; return
        }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        let url = folder.appendingPathComponent("CLIP_\(f.string(from: Date())).mov")
        do {
            let w = try AVAssetWriter(url: url, fileType: .mov)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: 2160,
                AVVideoHeightKey: 3840,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 150_000_000,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
                ]
            ])
            v.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 256_000
            ])
            a.expectsMediaDataInRealTime = true
            let ad = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: v,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 2160,
                    kCVPixelBufferHeightKey as String: 3840,
                    kCVPixelBufferMetalCompatibilityKey as String: true
                ])
            w.add(v); w.add(a)
            guard w.startWriting() else { throw w.error ?? NSError(domain: "writer", code: 1) }
            lock.lock()
            writer = w; vInput = v; aInput = a; adaptor = ad
            sessionStarted = false; recordingFolder = folder
            lock.unlock()
            isRecording = true
            message = ""
        } catch {
            folder.stopAccessingSecurityScopedResource()
            message = "เริ่มอัดไม่ได้: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        lock.lock()
        let w = writer, v = vInput, a = aInput, folder = recordingFolder, started = sessionStarted
        writer = nil; vInput = nil; aInput = nil; adaptor = nil
        sessionStarted = false; recordingFolder = nil
        lock.unlock()
        isRecording = false
        guard let w else { return }
        videoQueue.async {
            self.audioQueue.sync {}   // รอ callback เสียงที่ค้างอยู่
            if started {
                v?.markAsFinished(); a?.markAsFinished()
                w.finishWriting {
                    folder?.stopAccessingSecurityScopedResource()
                    DispatchQueue.main.async { self.message = "บันทึกแล้ว" }
                }
            } else {
                w.cancelWriting()
                folder?.stopAccessingSecurityScopedResource()
            }
        }
    }

    // MARK: Frame handling
    private func handleVideo(_ sb: CMSampleBuffer) {
        lock.lock(); let w = writer, v = vInput, ad = adaptor; lock.unlock()
        guard let w, let v, let ad, w.status == .writing,
              let src = CMSampleBufferGetImageBuffer(sb) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        lock.lock()
        if !sessionStarted { w.startSession(atSourceTime: pts); sessionStarted = true }
        lock.unlock()
        guard v.isReadyForMoreMediaData, let pool = ad.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }
        lock.lock(); let c = cube; lock.unlock()
        c.setValue(CIImage(cvPixelBuffer: src), forKey: kCIInputImageKey)
        if let img = c.outputImage { ciContext.render(img, to: out) }
        ad.append(out, withPresentationTime: pts)
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        lock.lock(); let w = writer, a = aInput, started = sessionStarted; lock.unlock()
        guard let w, let a, started, w.status == .writing, a.isReadyForMoreMediaData else { return }
        a.append(sb)
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOut { handleVideo(sampleBuffer) } else { handleAudio(sampleBuffer) }
    }
}
