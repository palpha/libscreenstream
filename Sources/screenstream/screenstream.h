#ifndef SCREENSTREAM_H
#define SCREENSTREAM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Struct for window info
typedef struct {
    int32_t windowId;
    int32_t processId;
    const char* title;
    const char* applicationName;
    int32_t width;
    int32_t height;
} ScreenStreamWindowInfo;

// Callback for window list
typedef void (*WindowListCallback)(const void* windows, int32_t count);

// Callback for thumbnail data
typedef void (*ThumbnailCallback)(const uint8_t* data, int32_t length);

// Struct for application info
typedef struct {
    int32_t processId;
    const char* name;
    const char* bundleIdentifier;
} ScreenStreamApplicationInfo;

// Callback for application list
typedef void (*ApplicationListCallback)(const void* apps, int32_t count);

// Error struct
typedef struct {
    int32_t code;
    const char* domain;
    const char* description;
} ScreenStreamError;

typedef void (*ScreenStreamErrorCallback)(const void* errorPtr);

// API functions
void CheckCapturePermission(void);
bool IsCapturePermissionGranted(void);
int32_t StartCapture(
    int32_t displayId,
    int32_t x, int32_t y,
    int32_t width, int32_t height,
    int32_t frameRate,
    int32_t fullScreenFrameRate,
    void (*regionCallback)(const uint8_t*, int32_t),
    void (*fullScreenCallback)(const uint8_t*, int32_t),
    ScreenStreamErrorCallback regionStoppedCallback,
    ScreenStreamErrorCallback fullScreenStoppedCallback
);
int32_t StopCapture(void);
int32_t GetCaptureStatus(void);
int32_t GetRegionBufferStats(void);
int32_t GetFullScreenBufferStats(void);
int32_t GetRegionFrameDropStats(void);
int32_t GetFullScreenFrameDropStats(void);
void ResetPerformanceStats(void);

// New API for window/application listing and thumbnails
void GetAvailableWindows(const void* callback);
void GetWindowThumbnail(int32_t windowId, ThumbnailCallback callback);
void GetAvailableApplications(const void* callback);

#ifdef __cplusplus
}
#endif

#endif // SCREENSTREAM_H
