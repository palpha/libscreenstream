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
        let domainCString = strdup(nsError.domain)
        let descCString = strdup(nsError.localizedDescription)
        var errStruct = ScreenStreamError(code: code, domain: domainCString, description: descCString)
        withUnsafePointer(to: &errStruct) { ptr in
            callback(UnsafeRawPointer(ptr))
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
        onFrameCaptured: { frameData in
            frameData.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                regionCallback(
                    baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
            }
        },
        onFullScreenCaptured: { frameData in
            frameData.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                fullScreenCallback(
                    baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
            }
        })

    // Set up stopped callbacks for C interop
    if let regionStoppedCallback = regionStoppedCallback {
        capturer.onRegionStopped = { error in
            callErrorCallback(regionStoppedCallback, error: error)
        }
    }
    if let fullScreenStoppedCallback = fullScreenStoppedCallback {
        capturer.onFullScreenStopped = { error in
            callErrorCallback(fullScreenStoppedCallback, error: error)
        }
    }

    globalCapturer = capturer
    captureStatus = .success

    // Fire off the actual capture asynchronously:
    Task {
        do {
            try await capturer.startCapturing()
        } catch let error as CaptureError {
            captureStatus = error
        } catch {
            captureStatus = .unknownError
        }
    }

    // The immediate return from this function indicates only that we *started* capture.
    // Return success or any initialization error you want:
    return CaptureError.success.rawValue
}

@MainActor
@available(macOS 12.3, *)
@_cdecl("StopCapture")
public func StopCapture() -> Int32 {
    let localCapturer = globalCapturer
    globalCapturer = nil

    Task {
        do {
            try await localCapturer?.stopCapturing()
        } catch {
            // If needed, hop back onto main actor to set status
            Task { @MainActor in
                captureStatus = .unknownError
            }
        }
    }

    return captureStatus.rawValue
}

@MainActor
@_cdecl("GetCaptureStatus")
public func GetCaptureStatus() -> Int32 {
    return captureStatus.rawValue
}
