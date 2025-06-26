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

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = self.width
        let height = self.height
        let expectedBytesPerRow = width * 3
        let totalBytes = height * expectedBytesPerRow

        // Process pixel buffer synchronously
        var frameData = Data(count: totalBytes)
        frameData.withUnsafeMutableBytes { dstPtr in
            let dstBase = dstPtr.baseAddress!.bindMemory(to: UInt8.self, capacity: totalBytes)
            let srcBase = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            for row in 0..<height {
                let srcRow = srcBase.advanced(by: row * bytesPerRow)
                let dstRow = dstBase.advanced(by: row * expectedBytesPerRow)
                for col in 0..<width {
                    let srcIndex = col * 4
                    let dstIndex = col * 3
                    dstRow[dstIndex + 0] = srcRow[srcIndex + 2] // B -> R
                    dstRow[dstIndex + 1] = srcRow[srcIndex + 1] // G
                    dstRow[dstIndex + 2] = srcRow[srcIndex + 0] // R -> B
                }
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
