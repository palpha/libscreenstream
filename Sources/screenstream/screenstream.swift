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

enum CaptureError: Int32, Error {
    case success = 0
    case initializationFailed = 1
    case noDisplaysFound = 2
    case startCaptureFailed = 3
    case unknownError = 99
}

@available(macOS 12.3, *)
@MainActor
var globalCapturer: ScreenCapturer?

@MainActor
var captureStatus: CaptureError = .success

@MainActor
var capturePermissionGranted: Bool = false

// Buffer pool for frame data reuse
final class BufferPool: @unchecked Sendable {
    private var availableBuffers: [Int: [Data]] = [:]  // Size -> [Buffers]
    private let queue = DispatchQueue(label: "buffer.pool", qos: .userInteractive)
    private let maxBuffersPerSize = 3  // Limit buffers per size bucket

    func getBuffer(size: Int) -> Data {
        return queue.sync {
            // Try exact size match first
            if var buffers = availableBuffers[size], !buffers.isEmpty {
                let buffer = buffers.removeLast()
                availableBuffers[size] = buffers.isEmpty ? nil : buffers
                return buffer
            }

            // Try larger buffers (within reason - max 25% larger)
            let maxAcceptableSize = size + (size / 4)
            for candidateSize in (size + 1)...maxAcceptableSize {
                if var buffers = availableBuffers[candidateSize], !buffers.isEmpty {
                    let buffer = buffers.removeLast()
                    availableBuffers[candidateSize] = buffers.isEmpty ? nil : buffers
                    // Resize the buffer in-place if possible, or return as-is if close enough
                    if buffer.count - size <= size / 10 {  // Within 10% is close enough
                        return buffer
                    } else {
                        return Data(buffer.prefix(size))
                    }
                }
            }

            // Create new buffer if no reusable one found
            return Data(count: size)
        }
    }

    func returnBuffer(_ buffer: Data) {
        queue.sync {
            let size = buffer.count
            var buffers = availableBuffers[size] ?? []

            // Only keep if we haven't hit the limit for this size
            if buffers.count < maxBuffersPerSize {
                buffers.append(buffer)
                availableBuffers[size] = buffers
            }
        }
    }
}

let regionBufferPool = BufferPool()
let fullScreenBufferPool = BufferPool()

@available(macOS 12.3, *)
public func checkCapturePermission() async {
    do {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        await MainActor.run {
            capturePermissionGranted = true
        }
    } catch {
        await MainActor.run {
            capturePermissionGranted = false
        }
    }
}

@MainActor
@available(macOS 12.3, *)
@_cdecl("CheckCapturePermission")
public func CheckCapturePermission() {
    Task {
        await checkCapturePermission()
    }
}

@MainActor
@available(macOS 12.3, *)
@_cdecl("IsCapturePermissionGranted")
public func IsCapturePermissionGranted() -> Bool {
    return capturePermissionGranted
}

// C struct for error interop
//
// NOTE: This struct must be public because it is used in a public API.
// The callback type uses UnsafeRawPointer? for Swift/C compatibility.
public struct ScreenStreamError {
    public var code: Int32
    public var domain: UnsafePointer<CChar>?
    public var description: UnsafePointer<CChar>?
}

// Use UnsafeRawPointer? for C interop; cast to ScreenStreamError* in C/.NET
public typealias ScreenStreamErrorCallback = @convention(c) (UnsafeRawPointer?) -> Void

// Helper to create and call the error callback with NSError support
func callErrorCallback(_ callback: ScreenStreamErrorCallback?, error: Error?) {
    guard let callback = callback else { return }
    if let error = error {
        let nsError = error as NSError
        let code: Int32 = Int32(nsError.code)

        // Use safe string conversion that doesn't require manual memory management
        // Avoid string copying by using the original NSString backing storage
        let domain = nsError.domain
        let description = nsError.localizedDescription

        // Use withCString to avoid string allocation/copying
        domain.utf8CString.withUnsafeBufferPointer { domainBuffer in
            description.utf8CString.withUnsafeBufferPointer { descBuffer in
                var errStruct = ScreenStreamError(
                    code: code,
                    domain: domainBuffer.baseAddress,
                    description: descBuffer.baseAddress
                )
                withUnsafePointer(to: &errStruct) { ptr in
                    callback(UnsafeRawPointer(ptr))
                }
            }
        }
    } else {
        callback(nil)
    }
}

@available(macOS 12.3, *)
@MainActor
@_cdecl("StartCapture")
public func StartCapture(
    displayId: Int32,
    x: Int32,
    y: Int32,
    width: Int32,
    height: Int32,
    frameRate: Int32,
    fullScreenFrameRate: Int32,
    regionCallback: @convention(c) (UnsafePointer<UInt8>, Int32) -> Void,
    fullScreenCallback: @convention(c) (UnsafePointer<UInt8>, Int32) -> Void,
    regionStoppedCallback: ScreenStreamErrorCallback? = nil,
    fullScreenStoppedCallback: ScreenStreamErrorCallback? = nil
) -> Int32 {
    // Validate input parameters to prevent crashes
    guard displayId >= 0,
          x >= 0, y >= 0,
          width > 0, height > 0,
          frameRate > 0, fullScreenFrameRate > 0 else {
        return CaptureError.initializationFailed.rawValue
    }

    // Build config
    let config = ScreenCapturerConfig(
        displayId: displayId,
        x: x, y: y,
        width: width, height: height,
        frameRate: frameRate,
        fullScreenFrameRate: fullScreenFrameRate
    )

    let capturer = ScreenCapturer(
        config: config,
        onFrameCaptured: { @Sendable frameData in
            // Get a reusable buffer from the pool
            var buffer = regionBufferPool.getBuffer(size: frameData.count)

            // Copy the frame data to our managed buffer
            buffer.withUnsafeMutableBytes { bufferPtr in
                frameData.withUnsafeBytes { dataPtr in
                    bufferPtr.copyMemory(from: dataPtr)
                }
            }

            // Call the C callback with our managed buffer
            buffer.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else {
                    regionBufferPool.returnBuffer(buffer)
                    return
                }
                regionCallback(
                    baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
            }

            // Return buffer to pool for reuse
            regionBufferPool.returnBuffer(buffer)
        },
        onFullScreenCaptured: { @Sendable frameData in
            // Get a reusable buffer from the pool
            var buffer = fullScreenBufferPool.getBuffer(size: frameData.count)

            // Copy the frame data to our managed buffer
            buffer.withUnsafeMutableBytes { bufferPtr in
                frameData.withUnsafeBytes { dataPtr in
                    bufferPtr.copyMemory(from: dataPtr)
                }
            }

            // Call the C callback with our managed buffer
            buffer.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else {
                    fullScreenBufferPool.returnBuffer(buffer)
                    return
                }
                fullScreenCallback(
                    baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
            }

            // Return buffer to pool for reuse
            fullScreenBufferPool.returnBuffer(buffer)
        })

    // Set up stopped callbacks for C interop
    if let regionStoppedCallback = regionStoppedCallback {
        capturer.onRegionStopped = { @Sendable error in
            callErrorCallback(regionStoppedCallback, error: error)
        }
    }
    if let fullScreenStoppedCallback = fullScreenStoppedCallback {
        capturer.onFullScreenStopped = { @Sendable error in
            callErrorCallback(fullScreenStoppedCallback, error: error)
        }
    }

    globalCapturer = capturer
    captureStatus = .success

    // Start capturing asynchronously without blocking
    Task {
        do {
            try await capturer.startCapturing()
            // Success - capturer is already set above
        } catch let error as CaptureError {
            await MainActor.run {
                captureStatus = error
                globalCapturer = nil
            }
        } catch {
            await MainActor.run {
                captureStatus = .unknownError
                globalCapturer = nil
            }
        }
    }

    // Return success immediately since we started the async operation
    return CaptureError.success.rawValue
}

@available(macOS 12.3, *)
@MainActor
@_cdecl("StopCapture")
public func StopCapture() -> Int32 {
    let localCapturer = globalCapturer
    globalCapturer = nil

    // Start async stop, but return immediately to avoid deadlock
    Task {
        do {
            try await localCapturer?.stopCapturing()
            // Optionally update captureStatus here if needed
        } catch {
            await MainActor.run {
                captureStatus = .unknownError
            }
        }
    }
    // Return current status immediately; stopped callbacks will notify C#
    return captureStatus.rawValue
}

@MainActor
@_cdecl("GetCaptureStatus")
public func GetCaptureStatus() -> Int32 {
    return captureStatus.rawValue
}
