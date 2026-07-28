# RNode and radio interfaces

Lower Sideband can run Reticulum directly over compatible [RNode](https://unsigned.io/rnode/) hardware without a Python bridge. The host implementation is the first production subsystem in the standalone `ReticulumKit` Swift module.

## Supported transports

- Wi-Fi/TCP on macOS, iPhone, and iPad — automated production acceptance complete
- Bluetooth LE on macOS, iPhone, and iPad — implemented; physical-device acceptance pending
- USB serial on macOS — implemented; physical-device acceptance pending
- Deterministic simulated transport on developer builds/tests

Multiple radio and IP interfaces can remain active concurrently so the path table can select independent routes.

## Protocol support

The conformance baseline for this milestone is:

- pinned Reticulum source `de0f399a1696895dcb95ad1efa19f3b21a7886ab`;
- official RNode Firmware source `d39339f8f233324416e4e82a9d798c976d78aaea`;
- firmware wire version 1.86, with the upstream minimum-compatible rule of 1.52.

The native implementation includes:

- the complete command-byte map from official RNode Firmware `Framing.h`;
- upstream KISS framing and incremental decoding across arbitrary TCP chunks;
- detection and reconnect handshakes;
- frequency, bandwidth, spreading factor, coding rate, power, airtime, and flow-control configuration;
- explicit `CMD_READY` radio-queue polling and a bounded 128-packet host queue;
- RSSI, SNR, battery, temperature, airtime, channel-load, physical-modem, CSMA, lock, and randomness metrics;
- station/callsign beacon scheduling;
- 64 × 64 one-bit framebuffer writes and display snapshots;
- ROM reads and board/platform/firmware metadata;
- firmware image digest, platform, and board validation;
- safe transition into device update mode;
- Bluetooth state restoration and bounded fragmentation;
- radio blink and deterministic packet-loopback diagnostics.

## Firmware updates

Lower Sideband validates a selected firmware package against the connected board and prepares an update plan before placing hardware into update mode. `RNodeChunkedFirmwareFlasher` provides bounded writes, cancellation and final SHA-256 verification to native BLE/serial/Wi-Fi bootloader adapters. On macOS, `RNodeExternalBootloaderFlasher` can hand a protected temporary image to an explicitly installed ESP, Nordic or AVR vendor tool and requires a successful exit status. The app does not claim that firmware was installed merely because update mode was entered.

Always obtain firmware from a trusted source and verify that it targets the detected platform and board.

## Configuration

Network Status provides regional starting presets and advanced manual radio settings. The operator remains responsible for:

- selecting legal frequencies and power levels;
- respecting local duty-cycle and airtime rules;
- using an antenna suitable for the configured band;
- matching network parameters used by intended peers;
- understanding that configuration errors can prevent delivery without producing an application fault.

## Testing without hardware

Focused protocol conformance, real local TCP socket, lifecycle, fuzz, and 2,500-packet simulated-radio tests:

```sh
Scripts/test-rnode.sh protocol
```

Compile both app platforms as well:

```sh
Scripts/test-rnode.sh all
```

## Physical acceptance test

Physical-device validation is intentionally still required before the overall RNode implementation, BLE, or USB serial is described as certified. The automated milestone validates TCP/KISS host behavior, but it cannot prove RF hardware, antennas, power transitions, vendor bootloaders, BLE restoration, or serial-driver behavior.

1. Connect a current official-firmware RNode over Wi-Fi/TCP and add it in Network Status.
2. Confirm detection, firmware, platform, board, and radio metrics.
3. Use **Blink** to verify the selected physical device.
4. Confirm the intended radio configuration was accepted.
5. Exchange packets with another compatible node and watch RX/TX counters.
6. Test reconnect after radio power loss and application foreground/background transitions.
7. Repeat with TCP/public interfaces active to confirm independent routes remain stable.
8. Run sustained bidirectional traffic through a second physical Reticulum node and verify packet ordering, no queue overflow, and recovery after Wi-Fi interruption.
9. Repeat the acceptance matrix separately for BLE and macOS USB serial.
10. For every supported board, flash a signed catalogue image, reboot, verify the reported version and repeat the traffic test.

Hardware tests must not transmit outside authorised spectrum or power limits.
