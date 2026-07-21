# Lower Sideband release rules

- Treat every build as a development/TestFlight build unless the user explicitly calls it a release candidate (RC).
- Upload distributed builds to TestFlight only. Do not submit a build to App Review unless the user explicitly identifies it as an RC and asks for submission.
- Increment both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` for every change set intended for distribution.
- Use the personal Apple Developer team `DLV44BUBE7`; never sign or publish with the Haploos team.
- Commit and push each completed change set.
- Do not manually change DNS configuration.
