/*

    libscreenstream – Capture a region of a display and receive frames as a stream of byte arrays.
    Copyright (C) 2025  Niklas Bergius

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import CoreGraphics
import AppKit
import Accelerate
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ScreenCaptureKit

struct ScreenCapturerConfig {
    let displayId: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let frameRate: Int32
    let fullScreenFrameRate: Int32

    init(
        displayId: Int32,
        x: Int32, y: Int32,
        width: Int32, height: Int32,
        frameRate: Int32 = 30,
        fullScreenFrameRate: Int32 = 1
    ) {
        self.displayId = Int(displayId)
        self.x = Int(x)
        self.y = Int(y)
        self.width = Int(width)
        self.height = Int(height)
        self.frameRate = Int32(frameRate)
        self.fullScreenFrameRate = Int32(fullScreenFrameRate)
    }
}

struct ApplicationInfo {
    let name: String
    let processId: Int
    let bundleIdentifier: String?
}

struct WindowInfo {
    let title: String
    let windowId: Int
    let processId: Int
    let applicationName: String
    let width: Int
    let height: Int
    let layer: Int
    let alpha: Float
    let isOnScreen: Bool
}

@available(macOS 12.3, *)
class ScreenCapturer: NSObject {
    private let config: ScreenCapturerConfig
    private let onFrameCaptured: @Sendable (Data) -> Void
    private let onFullScreenCaptured: @Sendable (Data) -> Void

    private var regionOutput: CaptureOutput?
    private var fullScreenOutput: CaptureOutput?

    // Add callbacks for stopped events
    var onRegionStopped: (@Sendable (Error?) -> Void)?
    var onFullScreenStopped: (@Sendable (Error?) -> Void)?

    init(
        config: ScreenCapturerConfig,
        onFrameCaptured: @escaping @Sendable (Data) -> Void,
        onFullScreenCaptured: @escaping @Sendable (Data) -> Void
    ) {
        self.config = config
        self.onFrameCaptured = onFrameCaptured
        self.onFullScreenCaptured = onFullScreenCaptured
    }

    @MainActor
    func startCapturing() async throws {
        do {
            let shareableContent =
                try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true)

            guard
                let display = shareableContent.displays.first(where: {
                    $0.displayID == config.displayId
                })
            else {
                throw CaptureError.noDisplaysFound
            }

            let regionStoppedCallback = self.onRegionStopped
            let fullScreenStoppedCallback = self.onFullScreenStopped

            let regionOutput = CaptureOutput(
                display: display,
                x: config.x, y: config.y,
                width: config.width, height: config.height,
                frameRate: config.frameRate,
                onFrameCaptured: onFrameCaptured,
                onCaptureStopped: { @Sendable error in regionStoppedCallback?(error) })

            let fullScreenOutput = CaptureOutput(
                display: display,
                x: 0, y: 0,
                width: display.width, height: display.height,
                frameRate: 1,
                onFrameCaptured: onFullScreenCaptured,
                onCaptureStopped: { @Sendable error in fullScreenStoppedCallback?(error) })

            try await regionOutput.start()
            try await fullScreenOutput.start()

            self.regionOutput = regionOutput
            self.fullScreenOutput = fullScreenOutput
        } catch CaptureError.noDisplaysFound {
            throw CaptureError.noDisplaysFound
        } catch {
            throw CaptureError.startCaptureFailed
        }
    }

    @MainActor
    func stopCapturing() async throws {
        if let regionOutput = self.regionOutput {
            try await regionOutput.stop()
            self.regionOutput = nil
        }
        if let fullScreenOutput = self.fullScreenOutput {
            try await fullScreenOutput.stop()
            self.fullScreenOutput = nil
        }
    }
}

@available(macOS 12.3, *)
class CaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let display: SCDisplay
    private let x: Int
    private let y: Int
    private let width: Int
    private let height: Int
    private let frameRate: Int32
    private let onFrameCaptured: @Sendable (Data) -> Void
    private let onCaptureStopped: (@Sendable (Error?) -> Void)?

    private var frameBuffer: Data
    private var stream: SCStream?

    init(
        display: SCDisplay,
        x: Int, y: Int,
        width: Int, height: Int,
        frameRate: Int32,
        onFrameCaptured: @escaping @Sendable (Data) -> Void,
        onCaptureStopped: (@Sendable (Error?) -> Void)? = nil
    ) {
        self.display = display
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.onFrameCaptured = onFrameCaptured
        self.onCaptureStopped = onCaptureStopped

        self.frameBuffer = Data(count: Int(width * height * 3))
    }

    @MainActor
    func start() async throws {
        #if DEBUG
        print("Starting capture for display \(display.displayID) at \(x),\(y) with size \(width)x\(height) at \(frameRate) FPS")
        #endif

        let filter = SCContentFilter(
            display: display, excludingApplications: [], exceptingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = width
        streamConfig.height = height
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.minimumFrameInterval = CMTime(
            value: 1, timescale: frameRate)
        streamConfig.sourceRect = CGRect(
            x: x, y: y,
            width: width, height: height)
        streamConfig.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: self)
        self.stream = stream

        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive)
        )

        try await stream.startCapture()
    }

    @MainActor
    func stop() async throws {
        guard let stream = stream else {
            return
        }

        try await stream.stopCapture()

        // Always call the stop callback for normal stops too, not just errors
        if let onCaptureStopped = self.onCaptureStopped {
            onCaptureStopped(nil) // nil indicates normal stop
        }
    }

    // SCStreamDelegate method
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if let onCaptureStopped = self.onCaptureStopped {
            Task { @MainActor in
                onCaptureStopped(error)
            }
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        // Use modern vImage for safer and more efficient pixel format conversion
        let width = self.width
        let height = self.height
        let expectedBytesPerRow = width * 3
        let totalBytes = height * expectedBytesPerRow

        var frameData = Data(count: totalBytes)

        frameData.withUnsafeMutableBytes { dstBytes in
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let srcBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

            // Source buffer (BGRA)
            var srcBuffer = vImage_Buffer(
                data: srcBaseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: srcBytesPerRow
            )

            // Destination buffer (RGB)
            var dstBuffer = vImage_Buffer(
                data: dstBytes.baseAddress!,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: expectedBytesPerRow
            )

            // Convert BGRA8888 to RGB888 using vImage
            let error = vImageConvert_BGRA8888toRGB888(&srcBuffer, &dstBuffer, vImage_Flags(kvImageNoFlags))
            if error != kvImageNoError {
                print("vImageConvert_BGRA8888toRGB888 error: \(error)")
            }
        }

        // Call the callback directly since onFrameCaptured is already @Sendable
        onFrameCaptured(frameData)
    }

    deinit {
        #if DEBUG
        print("CaptureOutput deinitialized")
        #endif
    }
}

@available(macOS 12.3, *)
extension ScreenCapturer {
    static func getAvailableApplications() async throws -> [ApplicationInfo] {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return shareableContent.applications.map { app in
            ApplicationInfo(
                name: app.applicationName,
                processId: Int(app.processID),
                bundleIdentifier: app.bundleIdentifier
            )
        }
    }

    static func getAvailableWindows() async throws -> [WindowInfo] {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let cgWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [WindowInfo] = []
        for win in shareableContent.windows {
            // Find matching CGWindow info by windowID
            let cgInfo = cgWindows.first { cgWin in
                if let cgId = cgWin[kCGWindowNumber as String] as? Int, cgId == Int(win.windowID) {
                    return true
                }
                return false
            }
            let layer = (cgInfo?[kCGWindowLayer as String] as? Int) ?? 0
            let alpha = (cgInfo?[kCGWindowAlpha as String] as? Float) ?? 1.0
            let isOnScreen = (cgInfo?[kCGWindowIsOnscreen as String] as? Bool) ?? true
            windows.append(WindowInfo(
                title: win.title ?? "",
                windowId: Int(win.windowID),
                processId: Int(win.owningApplication?.processID ?? 0),
                applicationName: win.owningApplication?.applicationName ?? "",
                width: Int(win.frame.width),
                height: Int(win.frame.height),
                layer: layer,
                alpha: alpha,
                isOnScreen: isOnScreen
            ))
        }
        return windows
    }

    static func getWindowThumbnail(windowId: Int) async -> Data? {
        // Use public API only for now to avoid crash with private API
        return getWindowThumbnailCG(windowId: windowId)
    }
}

@available(macOS 12.3, *)
class StreamOutputHandler: NSObject, SCStreamOutput {
    private let handler: (CVPixelBuffer) -> Void
    init(_ handler: @escaping (CVPixelBuffer) -> Void) {
        self.handler = handler
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        handler(pixelBuffer)
    }
}

func pixelBufferToCGImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
    // Use CoreImage for safer pixel buffer to CGImage conversion
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext(options: [.workingColorSpace: CGColorSpace.sRGB as Any])
    return context.createCGImage(ciImage, from: ciImage.extent)
}
