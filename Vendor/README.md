# Vendored native components

`Codec2.xcframework` is an unmodified build of official Codec2 1.2.0 for
iOS device, universal iOS Simulator, and universal macOS. It provides native 700C,
1200, 1300, 1400, 1600, 2400, and 3200 bit/s speech codecs for LXMF voice
messages and LXST calls.

Rebuild it from the pinned public source with:

```sh
Scripts/build-codec2-xcframework.sh
```

Codec2 is licensed under LGPL-2.1. The complete application source and build
instructions allow recipients to relink a modified Codec2 build. See
`CODEC2-LICENSE.txt` and the repository `NOTICE`.
