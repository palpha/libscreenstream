# libscreenstream

Library to simplify capturing a screen region on macOS. The initial reason for its existence was to help build a cross-platform app in .NET. The existing ScreenCaptureKit interop bits didn't work well/at all.

## Building

    swift build -c release --arch arm64 --arch x86_64

This will produce a universal binary:

    ./.build/apple/Products/Release/libscreenstream.dylib

## Using from .NET

See [Livescape Companion](https://github.com/palpha/liveshift-companion).

## Licensing

This project is licensed under the GNU General Public License v3.0 (GPLv3), ensuring that any modifications or derivative works are also made available under the same license.

However, if you are interested in using this project under different terms—for example, to distribute a modified version without being bound by GPLv3—you may contact the project maintainer to discuss alternative licensing options. Additional permissions may be granted on a case-by-case basis.

For inquiries, please reach out via https://github.com/palpha/libscreenstream/issues.