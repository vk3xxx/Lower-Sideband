# Apple device acceptance

Lower Sideband includes a guided acceptance workspace in **Settings →
Advanced → Apple device acceptance**. It covers the application behaviours
that differ materially between Simulator and real Apple hardware:

- bidirectional messaging and delivery proofs;
- inline images and 1 MiB file transfers;
- voice messages and encrypted calls;
- trusted telemetry, maps and export;
- background recovery;
- camera and microphone permission recovery; and
- Wi-Fi/cellular network handover;
- VoiceOver, keyboard navigation, Dynamic Type, contrast and reduced motion;
- language, region, text expansion and right-to-left layout; and
- hour-long memory, power and recovery endurance.

Each run has a unique identifier and start time. Every scenario includes
explicit instructions, pass/fail state, bounded notes, timestamp, application
build and operating-system evidence. Results persist on the tested device and
can be exported as a versioned, cryptographically signed JSON report. Schema 3
also records the locale, preferred languages, low-power state, thermal state
and physical memory present when the evidence is generated.

The workspace labels Simulator runs clearly. Simulator evidence is useful for
development, but does not certify physical camera, microphone, background,
cellular or hardware behaviour. RNode and other radio-hardware acceptance
remains separately parked until supported physical devices are available.
A run is marked ready for release review only when every scenario passed on
physical Apple hardware.

The combined campaign is stricter than an individual report. It certifies only
when signed physical Mac, iPhone and iPad reports all cover the exact same app
build, every expected scenario is present and passed, each result's build and
OS match its report, and all test timestamps fall within the recorded run. The
settings screen lists every blocking reason instead of presenting incomplete
evidence as a pass.
