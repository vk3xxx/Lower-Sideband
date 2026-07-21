# Contributing to Lower Sideband

Thank you for helping improve Lower Sideband. The project values protocol correctness, privacy, accessibility, and predictable behaviour on constrained networks.

## Before opening a change

1. Search existing issues and recent commits.
2. For substantial protocol or product changes, open a proposal before investing in a large implementation.
3. Keep changes focused and explain any compatibility or privacy implications.
4. Never include private identities, signing material, user message content, or production credentials in an issue, fixture, or commit.

## Development setup

Clone the reference submodules and generate the Xcode project:

```sh
git clone --recurse-submodules https://github.com/vk3xxx/Lower-Sideband.git
cd Lower-Sideband
xcodegen generate
swift test
```

See [Building](docs/BUILDING.md) and [Testing](docs/TESTING.md) for the complete commands.

## Engineering expectations

- Keep shared protocol and state logic in `SidebandCore`.
- Keep Apple UI and platform adapters in `Sources/SidebandMac`.
- Add deterministic tests for packet layouts, persistence migrations, routing behaviour, and error paths.
- Treat all incoming network, contact, archive, attachment, and plugin data as untrusted.
- Preserve compatibility with older encrypted snapshots when changing persisted models.
- Use bounded allocations, timeouts, histories, and retries.
- Avoid adding a Python runtime to distributed targets.
- Document platform restrictions instead of hiding them.
- Update `project.yml`, then regenerate `MacSideband.xcodeproj` with XcodeGen.

## Verification

Run before submitting a pull request:

```sh
Scripts/check-repository.sh
swift test
xcodebuild -project MacSideband.xcodeproj -scheme SidebandMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MacSideband.xcodeproj -scheme SidebandIOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Protocol-specific changes should also run the relevant interoperability or RNode checks described in [Testing](docs/TESTING.md).

## Pull requests

Describe the user-visible outcome, implementation approach, tests performed, platform impact, and any remaining limitations. Screenshots are helpful for UI changes. Do not combine unrelated cleanup with a behavioural change unless the cleanup is necessary for that change.

By contributing, you agree that your contribution may be distributed under the repository's [CC BY-NC-SA 4.0 licence](LICENSE).
