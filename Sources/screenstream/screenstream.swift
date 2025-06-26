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
        let domain = nsError.domain
        let description = nsError.localizedDescription

        domain.withCString { domainPtr in
            description.withCString { descPtr in
                var errStruct = ScreenStreamError(code: code, domain: domainPtr, description: descPtr)
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
            // Copy data to ensure it remains valid for the callback duration
            let dataCopy = Data(frameData)
            dataCopy.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                regionCallback(
                    baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
            }
        },
        onFullScreenCaptured: { @Sendable frameData in
            // Copy data to ensure it remains valid for the callback duration
            let dataCopy = Data(frameData)
            dataCopy.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                fullScreenCallback(
                    baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
            }
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
