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
public func CheckCapturePermission() -> Void {
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

@MainActor
@available(macOS 12.3, *)
@_cdecl("StartCapture")
public func StartCapture(
    displayId: Int32,
    x: Int32,
    y: Int32,
    width: Int32,
    height: Int32,
    frameRate: Int32,
    callback: @convention(c) (UnsafePointer<UInt8>, Int32) -> Void
) -> Int32 {
    // Build config
    let config = ScreenCapturerConfig(
        displayId: displayId,
        x: x, y: y,
        width: width, height: height,
        frameRate: frameRate
    )

    let capturer = ScreenCapturer(config: config) { frameData in
        frameData.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            callback(baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
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
