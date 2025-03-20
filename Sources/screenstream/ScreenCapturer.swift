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
import ScreenCaptureKit

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
    private let onFrameCaptured: (Data) -> Void
    private let onFullScreenCaptured: (Data) -> Void

    private var regionOutput: CaptureOutput?
    private var fullScreenOutput: CaptureOutput?

    init(
        config: ScreenCapturerConfig,
        onFrameCaptured: @escaping (Data) -> Void,
        onFullScreenCaptured: @escaping (Data) -> Void
    ) {
        self.config = config
        self.onFrameCaptured = onFrameCaptured
        self.onFullScreenCaptured = onFullScreenCaptured
    }

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

            let regionOutput = CaptureOutput(
                display: display,
                x: config.x, y: config.y,
                width: config.width, height: config.height,
                frameRate: config.frameRate,
                onFrameCaptured: onFrameCaptured)

            let fullScreenOutput = CaptureOutput(
                display: display,
                x: 0, y: 0,
                width: display.width, height: display.height,
                frameRate: 1,
                onFrameCaptured: onFullScreenCaptured)

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

    func stopCapturing() async throws {
        if let regionOutput = regionOutput {
            try await regionOutput.stop()
            self.regionOutput = nil
        }
        if let fullScreenOutput = fullScreenOutput {
            try await fullScreenOutput.stop()
            self.fullScreenOutput = nil
        }
    }
}

@available(macOS 12.3, *)
class CaptureOutput: NSObject, SCStreamOutput {
    private let display: SCDisplay
    private let x: Int
    private let y: Int
    private let width: Int
    private let height: Int
    private let frameRate: Int32
    private let onFrameCaptured: (Data) -> Void

    private var frameBuffer: Data
    private var stream: SCStream?

    init(
        display: SCDisplay,
        x: Int, y: Int,
        width: Int, height: Int,
        frameRate: Int32,
        onFrameCaptured: @escaping (Data) -> Void
    ) {
        self.display = display
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.onFrameCaptured = onFrameCaptured

        self.frameBuffer = Data(count: Int(width * height * 3))
    }

    func start() async throws {
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

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        self.stream = stream

        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive)
        )

        try await stream.startCapture()
    }

    func stop() async throws {
        guard let stream = stream else {
            return
        }

        try await stream.stopCapture()
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

        // We'll produce 3 bytes per pixel in the final buffer.
        let expectedBytesPerRow = self.width * 3
        let totalBytes = self.height * expectedBytesPerRow

        // Prepare the buffer.
        frameBuffer.removeAll(keepingCapacity: true)
        frameBuffer.count = totalBytes

        frameBuffer.withUnsafeMutableBytes { dstPtr in
            // We'll copy row by row, skipping alpha in each pixel.
            let dstBase = dstPtr.baseAddress!.bindMemory(to: UInt8.self, capacity: totalBytes)
            let srcBase = baseAddress.bindMemory(to: UInt8.self, capacity: bytesPerRow * self.height)

            for row in 0..<self.height {
                let srcRow = srcBase.advanced(by: row * bytesPerRow)
                let dstRow = dstBase.advanced(by: row * expectedBytesPerRow)

                for col in 0..<self.width {
                    // BGRA => RGB
                    let srcIndex = col * 4
                    let dstIndex = col * 3

                    dstRow[dstIndex + 0] = srcRow[srcIndex + 2] // B -> R
                    dstRow[dstIndex + 1] = srcRow[srcIndex + 1] // G
                    dstRow[dstIndex + 2] = srcRow[srcIndex + 0] // R -> B
                }
            }
        }

        onFrameCaptured(frameBuffer)
    }
}
