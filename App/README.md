# App target

`LocalDictionary.xcodeproj` contains the native AppKit menu-bar target for macOS 15.0+ on Apple Silicon (arm64). The current public state is source-only; it does not provide an official signed or notarized binary.

The target builds from the tracked, reviewed subset in `ThirdParty/vendor`; no submodule, ignored research checkout, Homebrew dependency, or build-time download is required. Runtime `local.json` is optional and is read only from the current user's Application Support `LocalDictionary/LegacyConfig` directory. It is never copied into the App Bundle.

The App can query managed local dictionaries without legacy configuration. Optional AI features access only a user-configured third-party Provider. Selection lookup requires Accessibility permission; the App does not request screen recording, microphone, or system audio recording permission.

Original LocalDictionary project code is licensed under GPL-3.0-only. Vendored dependencies and dictionary data retain their separate licenses and rights.
