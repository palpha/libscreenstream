#ifndef SCREENSTREAM_H
#define SCREENSTREAM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int code;
    const char* domain;
    const char* description;
} ScreenStreamError;

typedef void (*ScreenStreamErrorCallback)(const ScreenStreamError* error);

#ifdef __cplusplus
}
#endif

#endif // SCREENSTREAM_H
