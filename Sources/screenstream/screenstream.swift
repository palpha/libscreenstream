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

import AppKit
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

private typealias CGSConnectionID = UInt32
private let CGSMainConnectionID: CGSConnectionID = 0

private typealias CGSHWCaptureWindowListFunc = @convention(c) (
    CGSConnectionID, UnsafeMutablePointer<UInt32>?, Int, UInt32
) -> CFArray

private func captureWindowThumbnail(windowId: UInt32) -> CGImage? {
    guard
        let handle = dlopen(
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    else {
        return nil
    }
    defer { dlclose(handle) }

    guard let sym = dlsym(handle, "CGSHWCaptureWindowList") else {
        return nil
    }

    let fn = unsafeBitCast(sym, to: CGSHWCaptureWindowListFunc.self)
    var winId = windowId
    let options: UInt32 = 0x2 | 0x4 | 0x8  // ignoreGlobalClipShape | bestResolution | fullSize
    let arr = fn(CGSMainConnectionID, &winId, 1, options) as NSArray

    if let img = arr.firstObject {
        return Unmanaged<CGImage>.fromOpaque(img as! UnsafeRawPointer).takeUnretainedValue()
    }
    return nil
}

private func cgImageToPNGData(_ cgImage: CGImage, size: CGSize? = nil) -> Data? {
    let finalImage: CGImage
    if let size = size, cgImage.width != Int(size.width) || cgImage.height != Int(size.height) {
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace.sRGB as Any])
        let scaled = ciImage.transformed(
            by: CGAffineTransform(
                scaleX: size.width / CGFloat(cgImage.width),
                y: size.height / CGFloat(cgImage.height)))
        if let scaledCG = context.createCGImage(scaled, from: CGRect(origin: .zero, size: size)) {
            finalImage = scaledCG
        } else {
            finalImage = cgImage
        }
    } else {
        finalImage = cgImage
    }
    let mutableData = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            mutableData, "public.png" as CFString, 1, nil)
    else {
        return nil
    }
    CGImageDestinationAddImage(destination, finalImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        return nil
    }
    return Data(mutableData)
}

// Background queue for screenshot generation like AltTab
let screenshotsQueue = DispatchQueue(label: "screenshots", qos: .userInteractive)

func getWindowThumbnailCG(windowId: Int, size: CGSize? = nil) -> Data? {
    // Use only public API for now - private API causes crashes in async contexts
    let winId = UInt32(windowId)
    let image = CGWindowListCreateImage(
        CGRect.null,
        .optionIncludingWindow,
        CGWindowID(winId),
        [.boundsIgnoreFraming, .bestResolution]
    )
    if let cgImage = image {
        return cgImageToPNGData(cgImage, size: size)
    }
    return nil
}

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

    // Performance monitoring
    private var outstandingBuffers: Int = 0
    private var totalBuffersCreated: Int = 0
    private var peakOutstandingBuffers: Int = 0
    private var lastWarningTime: CFAbsoluteTime = 0

    private func shouldWarnAboutPressure() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastWarningTime > 5.0 {  // Warn at most every 5 seconds
            lastWarningTime = now
            return true
        }
        return false
    }

    func getBuffer(size: Int) -> Data {
        return queue.sync {
            outstandingBuffers += 1
            peakOutstandingBuffers = max(peakOutstandingBuffers, outstandingBuffers)

            // Warn if we have too many outstanding buffers (indicates consumer can't keep up)
            if outstandingBuffers > 10 && shouldWarnAboutPressure() {
                print(
                    "WARNING: \(outstandingBuffers) outstanding buffers - consuming code's processing may be too slow"
                )
                print("Peak: \(peakOutstandingBuffers), Total created: \(totalBuffersCreated)")
            }

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
            totalBuffersCreated += 1
            return Data(count: size)
        }
    }

    func returnBuffer(_ buffer: Data) {
        queue.sync {
            outstandingBuffers -= 1
            let size = buffer.count
            var buffers = availableBuffers[size] ?? []

            // Only keep if we haven't hit the limit for this size
            if buffers.count < maxBuffersPerSize {
                buffers.append(buffer)
                availableBuffers[size] = buffers
            }
        }
    }

    func getStats() -> (outstanding: Int, peak: Int, totalCreated: Int) {
        return queue.sync {
            return (outstandingBuffers, peakOutstandingBuffers, totalBuffersCreated)
        }
    }

    func resetStats() {
        queue.sync {
            peakOutstandingBuffers = outstandingBuffers
            totalBuffersCreated = 0
        }
    }
}

let regionBufferPool = BufferPool()
let fullScreenBufferPool = BufferPool()

// Frame dropping logic
final class FrameDropper: @unchecked Sendable {
    private let queue = DispatchQueue(label: "frame.dropper", qos: .userInteractive)
    private var lastFrameTime: CFAbsoluteTime = 0
    private var droppedFrameCount: Int = 0
    private var totalFrameCount: Int = 0

    func shouldDropFrame(bufferPool: BufferPool) -> Bool {
        return queue.sync {
            totalFrameCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            let timeSinceLastFrame = now - lastFrameTime
            lastFrameTime = now

            let stats = bufferPool.getStats()

            // Drop frames if:
            // 1. Too many outstanding buffers (indicates consumer can't keep up)
            // 2. Frame rate is too high (less than 16ms between frames = >60 FPS)
            let shouldDrop =
                stats.outstanding > 15 || (timeSinceLastFrame < 0.016 && stats.outstanding > 5)

            if shouldDrop {
                droppedFrameCount += 1
                if droppedFrameCount % 10 == 0 {  // Log every 10th dropped frame
                    let dropRate = Double(droppedFrameCount) / Double(totalFrameCount) * 100
                    print(
                        "Frame dropping: \(droppedFrameCount)/\(totalFrameCount) (\(String(format: "%.1f", dropRate))%) - Outstanding buffers: \(stats.outstanding)"
                    )
                }
            }

            return shouldDrop
        }
    }

    func getStats() -> (dropped: Int, total: Int, dropRate: Double) {
        return queue.sync {
            let rate =
                totalFrameCount > 0 ? Double(droppedFrameCount) / Double(totalFrameCount) * 100 : 0
            return (droppedFrameCount, totalFrameCount, rate)
        }
    }
}

let regionFrameDropper = FrameDropper()
let fullScreenFrameDropper = FrameDropper()

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
    guard displayId >= 0,
        x >= 0, y >= 0,
        width > 0, height > 0,
        frameRate > 0, fullScreenFrameRate > 0
    else {
        return CaptureError.initializationFailed.rawValue
    }

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
            // Check if we should drop this frame due to performance issues
            if regionFrameDropper.shouldDropFrame(bufferPool: regionBufferPool) {
                return  // Drop the frame
            }

            var buffer = regionBufferPool.getBuffer(size: frameData.count)
            buffer.withUnsafeMutableBytes { bufferPtr in
                frameData.withUnsafeBytes { dataPtr in
                    bufferPtr.copyMemory(from: dataPtr)
                }
            }
            buffer.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else {
                    regionBufferPool.returnBuffer(buffer)
                    return
                }
                regionCallback(
                    baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
            }

            regionBufferPool.returnBuffer(buffer)
        },
        onFullScreenCaptured: { @Sendable frameData in
            // Check if we should drop this frame due to performance issues
            if fullScreenFrameDropper.shouldDropFrame(bufferPool: fullScreenBufferPool) {
                return  // Drop the frame
            }

            var buffer = fullScreenBufferPool.getBuffer(size: frameData.count)
            buffer.withUnsafeMutableBytes { bufferPtr in
                frameData.withUnsafeBytes { dataPtr in
                    bufferPtr.copyMemory(from: dataPtr)
                }
            }

            buffer.withUnsafeBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else {
                    fullScreenBufferPool.returnBuffer(buffer)
                    return
                }
                fullScreenCallback(
                    baseAddress.assumingMemoryBound(to: UInt8.self), Int32(bufferPointer.count))
            }

            fullScreenBufferPool.returnBuffer(buffer)
        })

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

    return CaptureError.success.rawValue
}

@available(macOS 12.3, *)
@MainActor
@_cdecl("StopCapture")
public func StopCapture() -> Int32 {
    let localCapturer = globalCapturer
    globalCapturer = nil

    Task {
        do {
            try await localCapturer?.stopCapturing()
        } catch {
            await MainActor.run {
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

@_cdecl("GetRegionBufferStats")
public func GetRegionBufferStats() -> Int32 {
    let stats = regionBufferPool.getStats()
    return Int32(stats.outstanding)
}

@_cdecl("GetFullScreenBufferStats")
public func GetFullScreenBufferStats() -> Int32 {
    let stats = fullScreenBufferPool.getStats()
    return Int32(stats.outstanding)
}

@_cdecl("GetRegionFrameDropStats")
public func GetRegionFrameDropStats() -> Int32 {
    let stats = regionFrameDropper.getStats()
    return Int32(stats.dropRate * 100)  // Return drop rate as percentage * 100
}

@_cdecl("GetFullScreenFrameDropStats")
public func GetFullScreenFrameDropStats() -> Int32 {
    let stats = fullScreenFrameDropper.getStats()
    return Int32(stats.dropRate * 100)  // Return drop rate as percentage * 100
}

@_cdecl("ResetPerformanceStats")
public func ResetPerformanceStats() {
    regionBufferPool.resetStats()
    fullScreenBufferPool.resetStats()
}

// MARK: - C Interop Structs
public struct ScreenStreamWindowInfo {
    public var windowId: Int32
    public var processId: Int32
    public var title: UnsafePointer<CChar>?
    public var applicationName: UnsafePointer<CChar>?
    public var width: Int32
    public var height: Int32
}

public struct ScreenStreamApplicationInfo {
    public var processId: Int32
    public var name: UnsafePointer<CChar>?
    public var bundleIdentifier: UnsafePointer<CChar>?
}

@available(macOS 12.3, *)
@_cdecl("GetAvailableWindows")
public func GetAvailableWindows(callbackPtr: UnsafeRawPointer?) {
    guard let callbackPtr = callbackPtr else { return }
    let callbackAddress = Int(bitPattern: callbackPtr)

    Task {
        do {
            let windows = try await ScreenCapturer.getAvailableWindows()
            var infos: [ScreenStreamWindowInfo] = []

            for win in windows {
                let titlePtr: UnsafePointer<CChar>? = win.title.isEmpty ? nil : UnsafePointer(strdup(win.title))
                let appNamePtr: UnsafePointer<CChar>? = win.applicationName.isEmpty ? nil : UnsafePointer(strdup(win.applicationName))
                infos.append(
                    ScreenStreamWindowInfo(
                        windowId: Int32(win.windowId),
                        processId: Int32(win.processId),
                        title: titlePtr,
                        applicationName: appNamePtr,
                        width: Int32(win.width),
                        height: Int32(win.height)
                    ))
            }

            let callback = unsafeBitCast(
                UnsafeRawPointer(bitPattern: callbackAddress)!,
                to: (@convention(c) (UnsafeRawPointer?, Int32) -> Void).self)
            infos.withUnsafeBytes { infoBytes in
                callback(infoBytes.baseAddress, Int32(infos.count))
            }

        } catch {
            let callback = unsafeBitCast(
                UnsafeRawPointer(bitPattern: callbackAddress)!,
                to: (@convention(c) (UnsafeRawPointer?, Int32) -> Void).self)
            callback(nil, 0)
        }
    }
}

@available(macOS 12.3, *)
@_cdecl("GetWindowThumbnail")
public func GetWindowThumbnail(windowId: Int32, callbackPtr: UnsafeRawPointer?) {
    guard let callbackPtr = callbackPtr else { return }
    let callbackAddress = Int(bitPattern: callbackPtr)

    // Use background queue for thumbnail generation like AltTab
    screenshotsQueue.async {
        let data = getWindowThumbnailCG(windowId: Int(windowId))
        // Reconstruct the callback from the address
        let callback = unsafeBitCast(
            UnsafeRawPointer(bitPattern: callbackAddress)!,
            to: (@convention(c) (UnsafePointer<UInt8>?, Int32) -> Void).self)
        if let data = data {
            // Use same pattern as StartCapture - call within withUnsafeBytes scope
            data.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else {
                    callback(nil, 0)
                    return
                }
                callback(base.assumingMemoryBound(to: UInt8.self), Int32(ptr.count))
            }
        } else {
            callback(nil, 0)
        }
    }
}

@available(macOS 12.3, *)
@_cdecl("GetAvailableApplications")
public func GetAvailableApplications(callbackPtr: UnsafeRawPointer?) {
    guard let callbackPtr = callbackPtr else { return }

    // Capture the callback address for Sendable compatibility
    let callbackAddress = Int(bitPattern: callbackPtr)

    Task {
        do {
            let apps = try await ScreenCapturer.getAvailableApplications()
            var infos: [ScreenStreamApplicationInfo] = []
            for app in apps {
                let namePtr = strdup(app.name)
                let bundlePtr = app.bundleIdentifier != nil ? strdup(app.bundleIdentifier!) : nil
                infos.append(
                    ScreenStreamApplicationInfo(
                        processId: Int32(app.processId),
                        name: namePtr,
                        bundleIdentifier: bundlePtr
                    ))
            }

            let callback = unsafeBitCast(
                UnsafeRawPointer(bitPattern: callbackAddress)!,
                to: (@convention(c) (UnsafeRawPointer?, Int32) -> Void).self)
            infos.withUnsafeBytes { infoBytes in
                callback(infoBytes.baseAddress, Int32(infos.count))
            }
        } catch {
            let callback = unsafeBitCast(
                UnsafeRawPointer(bitPattern: callbackAddress)!,
                to: (@convention(c) (UnsafeRawPointer?, Int32) -> Void).self)
            callback(nil, 0)
        }
    }
}
