import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Takes a still from each camera. Used when the user corrects the appearance,
/// so every label comes with what the room looked like, and optionally on a
/// schedule so the camera can become a predictor too.
///
/// macOS exposes neither exposure time nor ISO for capture devices, so luma is
/// mostly what auto-exposure aimed for; EXIF brightness is recorded when a
/// camera provides it. The photos themselves are kept for you to look at.
public final class Cameras: @unchecked Sendable {
    public init() {}

    public static var authorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// Cameras matching `filter` (substring of the name); all if empty.
    public static func devices(matching filter: String = "") -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.filter { filter.isEmpty || $0.localizedName.localizedCaseInsensitiveContains(filter) }
    }

    /// One still per matching camera, captured in parallel after letting
    /// auto-exposure settle. Photos go into `directory` if given.
    public func capture(matching filter: String, into directory: URL?,
                        settle: TimeInterval = 1.5) async -> [CameraSample] {
        guard Self.authorized else { return [] }
        // AVCaptureDevice is not Sendable; hand each task its ID instead.
        let ids = Self.devices(matching: filter).map(\.uniqueID)
        return await withTaskGroup(of: CameraSample?.self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask {
                    guard let d = AVCaptureDevice(uniqueID: id) else { return nil }
                    return await Grabber(device: d, index: i, directory: directory, settle: settle).run()
                }
            }
            var out: [CameraSample] = []
            for await s in group { if let s { out.append(s) } }
            return out.sorted { $0.device < $1.device }
        }
    }
}

private final class Grabber: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let device: AVCaptureDevice
    let index: Int
    let directory: URL?
    let settle: TimeInterval
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dusk.camera")
    private var started = Date()
    private var continuation: CheckedContinuation<CameraSample?, Never>?

    init(device: AVCaptureDevice, index: Int, directory: URL?, settle: TimeInterval) {
        self.device = device
        self.index = index
        self.directory = directory
        self.settle = settle
    }

    func run() async -> CameraSample? {
        await withCheckedContinuation { (c: CheckedContinuation<CameraSample?, Never>) in
            queue.async { [self] in
                continuation = c
                guard let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else { return finish(nil) }
                session.beginConfiguration()
                session.sessionPreset = .medium
                session.addInput(input)
                let out = AVCaptureVideoDataOutput()
                out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                out.alwaysDiscardsLateVideoFrames = true
                out.setSampleBufferDelegate(self, queue: queue)
                guard session.canAddOutput(out) else { return finish(nil) }
                session.addOutput(out)
                session.commitConfiguration()
                started = Date()
                session.startRunning()
                queue.asyncAfter(deadline: .now() + settle + 5) { [self] in finish(nil) }  // no frames
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard continuation != nil, Date().timeIntervalSince(started) >= settle,
              let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        let luma = Self.meanLuma(image)
        var exif: Double?
        if let a = CMGetAttachment(buffer, key: kCGImagePropertyExifDictionary, attachmentModeOut: nil) as? [String: Any] {
            exif = a[kCGImagePropertyExifBrightnessValue as String] as? Double
        }
        var photo: String?
        if let directory {
            let name = "\(Int(Date().timeIntervalSince1970))-\(index).jpg"
            let url = directory.appendingPathComponent(name)
            if let cs = CGColorSpace(name: CGColorSpace.sRGB),
               let data = Self.context.jpegRepresentation(of: image, colorSpace: cs,
                                                          options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) {
                try? data.write(to: url)
                photo = name
            }
        }
        finish(CameraSample(device: device.localizedName + (index > 0 ? " #\(index + 1)" : ""),
                            luma: luma, exifBrightness: exif, photo: photo))
    }

    private func finish(_ s: CameraSample?) {
        guard let c = continuation else { return }
        continuation = nil
        session.stopRunning()
        c.resume(returning: s)
    }

    static let context = CIContext(options: [.workingColorSpace: NSNull()])

    /// Mean Rec. 709 luma over the whole frame, via a 1×1 area average.
    static func meanLuma(_ image: CIImage) -> Double {
        guard let f = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent),
        ]), let out = f.outputImage else { return 0 }
        var px = [UInt8](repeating: 0, count: 4)
        context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        // CIAreaAverage over BGRA input still renders as RGBA.
        let r = Double(px[0]), g = Double(px[1]), b = Double(px[2])
        return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
    }
}
