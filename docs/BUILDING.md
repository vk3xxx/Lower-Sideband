# Building and running

## Requirements

- macOS 14 or newer
- Xcode 16 or newer with macOS 14 and iOS 17 SDK support
- Swift 6 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the Xcode project
- A personal Apple Developer team only when signing a device build

## Clone

The upstream protocol references are Git submodules:

```sh
git clone --recurse-submodules https://github.com/vk3xxx/Lower-Sideband.git
cd Lower-Sideband
```

For an existing clone:

```sh
git submodule update --init --recursive
```

## Generate the project

`project.yml` is the canonical Xcode project definition:

```sh
xcodegen generate
```

Commit `project.yml` and the regenerated `MacSideband.xcodeproj/project.pbxproj` together. Numbered project copies are not canonical.

## Swift Package Manager

The shared core, macOS executable, and test suite can be built without opening Xcode:

```sh
swift build
swift test
swift run SidebandMac
```

The SwiftPM executable is useful for development. The provisioned Xcode macOS application is the distribution-equivalent target.

## macOS application

```sh
xcodebuild -project MacSideband.xcodeproj \
  -scheme SidebandMac \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Or open `MacSideband.xcodeproj`, select `SidebandMac`, and Run.

For a simple unsigned local bundle:

```sh
Scripts/package-macos-app.sh
open dist/Sideband.app
```

## iPhone and iPad

Unsigned simulator build:

```sh
xcodebuild -project MacSideband.xcodeproj \
  -scheme SidebandIOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Open the Xcode project to run on a selected simulator or provisioned device. A physical device is required to validate Bluetooth, background behaviour, camera, microphone, local-network permissions, and realistic radio/network transitions.

## Signing and distribution

The project is configured for Apple Developer team `DLV44BUBE7`. Never commit signing certificates, private keys, App Store Connect API keys, or provisioning profiles.

Repository release policy:

- all ordinary builds are development/TestFlight builds;
- both marketing and build versions are incremented for a distribution change set;
- App Review submission occurs only when a build is explicitly designated as a release candidate;
- distributed builds use TestFlight unless an explicit release-candidate instruction says otherwise.

Export options are stored in `Support/`. They contain configuration, not signing secrets.

## Troubleshooting

- **Build database locked:** use different `-derivedDataPath` values for simultaneous builds or run builds sequentially.
- **Project does not contain a new file:** run `xcodegen generate`.
- **Submodule import fails:** run `git submodule update --init --recursive`.
- **Local network is unavailable in Simulator:** test gateway/RNode behaviour on a physical device; Simulator networking is not identical to iOS hardware.
- **Messages remain queued:** inspect Network Status and conversation delivery diagnostics; a connected socket is not proof of a valid route or receipt.
