# Lower Sideband release rules

- Treat every build as a development/TestFlight build unless the user explicitly calls it a release candidate (RC).
- Upload distributed builds to TestFlight only. Do not submit a build to App Review unless the user explicitly identifies it as an RC and asks for submission.
- Every TestFlight request must publish the synchronized iPhone/iPad and native macOS builds. Keep both platforms on the same `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, and do not consider the request complete until both builds are available to the same TestFlight tester group.
- Increment both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for every change set intended for distribution.
- Treat every request to push or publish to TestFlight as a synchronized multi-platform release: upload both the iPhone/iPad (`SidebandIOS`) build and the native Mac (`SidebandMac`) build with identical `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` values. Never leave TestFlight with a newer build on only one of these platforms.
- Use the personal Apple Developer team `DLV44BUBE7`; never sign or publish with the Haploos team.
- Commit and push each completed change set.
- Do not manually change DNS configuration.
