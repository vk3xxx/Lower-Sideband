# RNode and radio interfaces

Lower Sideband can run Reticulum directly over compatible [RNode](https://unsigned.io/rnode/) hardware without a Python bridge.

## Supported transports

- Bluetooth LE on macOS, iPhone, and iPad
- Wi-Fi/TCP on macOS, iPhone, and iPad
- USB serial on macOS
- Deterministic simulated transport on developer builds/tests

Multiple radio and IP interfaces can remain active concurrently so the path table can select independent routes.

## Protocol support

The native implementation includes:

- upstream KISS framing and stream decoding;
- detection and reconnect handshakes;
- frequency, bandwidth, spreading factor, coding rate, power, airtime, and flow-control configuration;
- RSSI, SNR, battery, temperature, airtime, and channel-load metrics;
- station/callsign beacon scheduling;
- 64 × 64 one-bit framebuffer writes and display snapshots;
- ROM reads and board/platform/firmware metadata;
- firmware image digest, platform, and board validation;
- safe transition into device update mode;
- Bluetooth state restoration and bounded fragmentation;
- radio blink and deterministic packet-loopback diagnostics.

## Firmware updates

Lower Sideband validates a selected firmware package against the connected board and prepares an update plan before placing hardware into update mode. Bootloader flashing itself is platform- and board-specific and is intentionally handed off to the appropriate ESP, Nordic, or AVR flashing tool. The app does not claim that arbitrary firmware has been installed merely because update mode was entered.

Always obtain firmware from a trusted source and verify that it targets the detected platform and board.

## Configuration

Network Status provides regional starting presets and advanced manual radio settings. The operator remains responsible for:

- selecting legal frequencies and power levels;
- respecting local duty-cycle and airtime rules;
- using an antenna suitable for the configured band;
- matching network parameters used by intended peers;
- understanding that configuration errors can prevent delivery without producing an application fault.

## Testing without hardware

Focused protocol and 100-packet simulated-radio tests:

```sh
Scripts/test-rnode.sh protocol
```

Compile both app platforms as well:

```sh
Scripts/test-rnode.sh all
```

## Physical acceptance test

1. Add or discover the RNode in Network Status.
2. Confirm detection, firmware, platform, board, and radio metrics.
3. Use **Blink** to verify the selected physical device.
4. Confirm the intended radio configuration was accepted.
5. Exchange packets with another compatible node and watch RX/TX counters.
6. Test reconnect after radio power loss and application foreground/background transitions.
7. Repeat with TCP/public interfaces active to confirm independent routes remain stable.

Hardware tests must not transmit outside authorised spectrum or power limits.
