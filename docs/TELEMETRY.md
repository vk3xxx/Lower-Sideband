# Telemetry

Lower Sideband preserves the canonical Sideband telemetry MessagePack shape and
retains unknown sensor IDs losslessly. Typed native accessors now cover:

- location, battery, pressure, temperature, humidity, ambient light, and
  motion vectors;
- physical-link RSSI, SNR, and quality;
- power consumption and production entries;
- processor load, load averages, and clock;
- memory and non-volatile storage capacity/usage;
- tank and fuel capacity, level, unit, and icon metadata.

These accessors decode and encode the same nested array structures as Python
Sideband. The original encoded sensor remains available for forwarding, so a
newer or plugin-defined sensor is not discarded by an older Apple client.

## Alerts

The native alert API supports above/below rules for battery, environmental
sensors, link metrics, processor load, memory/storage usage, tank/fuel levels,
and total power consumption or production. Rules are bounded, Codable values
and evaluate locally without sending telemetry to a server.

## Export

Conversation telemetry can be exported as:

- CSV location history;
- GPX tracks;
- JSON containing all valid telemetry samples and lossless additional sensor
  payloads; or
- GeoJSON point features for mapping and GIS tools.

Exports are generated locally. They contain the selected conversation's
telemetry and should be handled as sensitive location/device information.
