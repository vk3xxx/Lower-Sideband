# Accessibility and localisation

Lower Sideband uses semantic SwiftUI controls and text styles so macOS and iOS
inherit VoiceOver, keyboard navigation, Dynamic Type, contrast, reduced-motion
and right-to-left behaviour from the operating system.

The network map disables viewport and panel animation when Reduce Motion is
enabled. Migration, support-export and device-acceptance workflows expose
stable automation identifiers, explicit outcome labels and task instructions
without relying on colour alone.

Conversation rows expose complete spoken summaries and VoiceOver actions for
read state, pinning and archiving. Primary messaging, settings, network status,
attachments, maps, voice controls and identity actions have explicit labels,
hints, values or stable automation identifiers where their visible content is
not sufficient.

User-facing source strings are collected in `Support/Localizable.xcstrings`.
New UI must use `Text`, `Label`, `String(localized:)` or localised format styles;
concatenated English fragments should be avoided. Before adding a translation:

1. export the Xcode string catalog;
2. translate complete semantic phrases with context;
3. test long strings, plural forms and right-to-left pseudolocalisation;
4. run VoiceOver on iPhone, iPad and Mac at accessibility text sizes;
5. verify controls remain keyboard accessible and do not rely on colour alone.

The English catalog is the reviewed source language. Additional languages
should only be marked complete after native-language review.

Development and release review must also exercise:

- right-to-left pseudolocalisation;
- accessibility text sizes without clipped actions;
- Increase Contrast, Differentiate Without Colour and Reduce Motion;
- Full Keyboard Access on iPad and macOS; and
- VoiceOver rotor navigation through settings, migration and acceptance rows.

`Scripts/validate-apple-quality.swift` fails when critical messaging,
settings, network-map or migration strings leave the shared catalog, when
essential VoiceOver/automation identifiers disappear, or when required
privacy and background declarations are missing. Run
`Scripts/run-production-quality-gates.sh all` for the complete deterministic
test and unsigned Release-build gate.

The gate also requires stable automation identifiers for every physical-device
acceptance scenario, Reduce Motion and Differentiate Without Color handling,
and a valid upstream compatibility manifest. Physical-device VoiceOver,
keyboard, Dynamic Type, contrast, language and region review is recorded in
the versioned Apple-device acceptance report.

`Support/AppleExperienceCertification.json` is the fail-closed experience
policy. It requires physical Mac, iPhone and iPad coverage for every core
workflow; VoiceOver, Voice Control and Switch Control; touch, pointer and
hardware keyboard input; all Dynamic Type sizes through AX5; light/dark and
accessibility appearances; English, text-expansion and right-to-left locales;
and an eight-hour large-history endurance run. The quality audit refuses policy
changes below 10,000 messages, 100 attachments, zero crashes/warnings and a 15%
memory-growth ceiling. Passing deterministic gates confirms the policy and UI
hooks exist; the signed physical-device reports remain the evidence that a
person actually completed it on each platform.
