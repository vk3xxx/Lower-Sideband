# Accessibility and localisation

Lower Sideband uses semantic SwiftUI controls and text styles so macOS and iOS
inherit VoiceOver, keyboard navigation, Dynamic Type, contrast, reduced-motion
and right-to-left behaviour from the operating system.

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

`Scripts/validate-apple-quality.swift` fails when critical messaging,
settings, network-map or migration strings leave the shared catalog, when
essential VoiceOver/automation identifiers disappear, or when required
privacy and background declarations are missing. Run
`Scripts/run-production-quality-gates.sh all` for the complete deterministic
test and unsigned Release-build gate.
