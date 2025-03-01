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

    init(
        displayId: Int32,
        x: Int32, y: Int32,
        width: Int32, height: Int32,
        frameRate: Int32 = 30
    ) {
        self.displayId = Int(displayId)
        self.x = Int(x)
        self.y = Int(y)
        self.width = Int(width)
        self.height = Int(height)
        self.frameRate = Int32(frameRate)
    }
}

@available(macOS 12.3, *)
class ScreenCapturer: NSObject, SCStreamOutput {
    private let config: ScreenCapturerConfig
    private var frameBuffer: Data
    private let onFrameCaptured: (Data) -> Void

    private var stream: SCStream?

    init(
        config: ScreenCapturerConfig,
        onFrameCaptured: @escaping (Data) -> Void
    ) {
        self.config = config
        self.frameBuffer = Data(count: Int(config.width * config.height * 4))
        self.onFrameCaptured = onFrameCaptured
    }

    func startCapturing() async throws {
        do {
            let shareableContent =
                try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true)

            guard let display = shareableContent.displays.first(where: {
                $0.displayID == config.displayId
            }) else {
                throw CaptureError.noDisplaysFound
            }

            let filter = SCContentFilter(
                display: display, excludingApplications: [], exceptingWindows: [])

            let streamConfig = SCStreamConfiguration()
            streamConfig.width = Int(config.width)
            streamConfig.height = Int(config.height)
            streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
            streamConfig.minimumFrameInterval = CMTime(
                value: 1, timescale: config.frameRate)
            streamConfig.sourceRect = CGRect(
                x: Int(config.x), y: Int(config.y),
                width: Int(config.width), height: Int(config.height))

            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
            self.stream = stream

            try stream.addStreamOutput(
                self, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive)
            )

            try await stream.startCapture()

            // catch everything but CaptureError.noDisplaysFound
        } catch CaptureError.noDisplaysFound {
            throw CaptureError.noDisplaysFound
        } catch {
            throw CaptureError.startCaptureFailed
        }
    }

    func stopCapturing() async throws {
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
        let expectedBytesPerRow = config.width * 4

        frameBuffer.removeAll(keepingCapacity: true)

        for row in 0..<config.height {
            let rowStart = baseAddress.advanced(by: row * bytesPerRow)
            frameBuffer.append(Data(bytes: rowStart, count: expectedBytesPerRow))
        }

        onFrameCaptured(frameBuffer)
    }
}
