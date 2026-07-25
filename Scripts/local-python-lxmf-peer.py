#!/usr/bin/env python3
"""Deterministic upstream RNS/LXMF peer for local Swift interoperability tests.

This is developer-only test support. It runs the pinned Python reference
implementation in a separate process and echoes accepted soak messages back to
their sender, preserving standard LXMF fields such as file and image
attachments. Nothing from this script is included in distributed app bundles.
"""

import argparse
import json
import os
import signal
import sys
import threading
import time
import traceback
from pathlib import Path

import LXMF
import RNS


class Peer:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.received = {}
        self.delivered = {}
        self.failed = {}
        self.reply_payloads = {}
        self.reply_retry_counts = {}
        self.reply_retry_due = {}
        self.reply_last_sent = {}
        self.reply_active_message_ids = {}
        self.reply_watchdog_cancelled = set()
        self.started_at = time.time()
        self.stop_event = threading.Event()

        RNS.Reticulum(configdir=args.config, loglevel=args.loglevel)
        original_inbound = RNS.Transport.inbound

        def traced_inbound(raw, interface=None):
            try:
                return original_inbound(raw, interface)
            except Exception:
                print(
                    "PYTHON_PEER_INBOUND_EXCEPTION "
                    + json.dumps(
                        {
                            "bytes": len(raw),
                            "interface": str(interface),
                            "raw_hex": raw.hex(),
                        },
                        sort_keys=True,
                    ),
                    flush=True,
                )
                traceback.print_exc()
                raise

        RNS.Transport.inbound = staticmethod(traced_inbound)
        original_link_receive = RNS.Link.receive

        def traced_link_receive(link, packet):
            if packet.context == RNS.Packet.RESOURCE_ADV:
                try:
                    plaintext = link.decrypt(packet.data)
                    advertisement = (
                        RNS.ResourceAdvertisement.unpack(plaintext)
                        if plaintext is not None
                        else None
                    )
                    print(
                        "PYTHON_PEER_RESOURCE_ADVERTISEMENT "
                        + json.dumps(
                            {
                                "decrypted": plaintext is not None,
                                "data_size": getattr(advertisement, "d", None),
                                "transfer_size": getattr(advertisement, "t", None),
                                "parts": getattr(advertisement, "n", None),
                                "map_bytes": len(getattr(advertisement, "m", b"")),
                                "flags": getattr(advertisement, "f", None),
                            },
                            sort_keys=True,
                        ),
                        flush=True,
                    )
                except Exception:
                    print("PYTHON_PEER_RESOURCE_ADVERTISEMENT_EXCEPTION", flush=True)
                    traceback.print_exc()
            return original_link_receive(link, packet)

        RNS.Link.receive = traced_link_receive
        storage = Path(args.storage)
        storage.mkdir(parents=True, exist_ok=True)
        identity_path = storage / "identity"
        if identity_path.exists():
            identity = RNS.Identity.from_file(str(identity_path))
        else:
            identity = RNS.Identity()
            identity.to_file(str(identity_path))

        self.router = LXMF.LXMRouter(
            storagepath=str(storage / "lxmf"),
            enforce_stamps=False,
            autopeer=False,
            # Stock LXMF defaults to 1,000 decimal KB, which rejects an exact
            # 1 MiB acceptance fixture before protocol transfer begins.
            delivery_limit=2_000,
        )
        self.source = self.router.register_delivery_identity(
            identity,
            display_name="Lower Sideband Python Reference",
            stamp_cost=None,
        )
        self.router.register_delivery_callback(self.receive)
        self.announced_interfaces = set()
        self.next_periodic_announce = 0
        self.write_report("ready")
        print(
            "PYTHON_PEER_READY "
            + json.dumps(
                {
                    "destination": self.source.hash.hex(),
                    "pid": os.getpid(),
                    "config": args.config,
                },
                sort_keys=True,
            ),
            flush=True,
        )

    def receive(self, message):
        body = message.content_as_string()
        if not body.startswith(self.args.inbound_prefix + "-"):
            return
        sequence = body.rsplit("-", 1)[-1]
        with self.lock:
            self.received[body] = {
                "message_id": message.message_id.hex(),
                "received_at": time.time(),
                "signature_validated": bool(message.signature_validated),
                "stamp_valid": bool(message.stamp_valid),
                "field_keys": sorted(str(key) for key in message.fields.keys()),
            }
        print(
            "PYTHON_PEER_RECEIVED "
            + json.dumps(
                {
                    "body": body,
                    "message_id": message.message_id.hex(),
                    "signature_validated": bool(message.signature_validated),
                },
                sort_keys=True,
            ),
            flush=True,
        )
        self.write_report("running")
        source_identity = RNS.Identity.recall(message.source_hash)
        if source_identity is None:
            self.failed[sequence] = "source identity unavailable"
            self.write_report("source-identity-unavailable")
            return
        destination = RNS.Destination(
            source_identity,
            RNS.Destination.OUT,
            RNS.Destination.SINGLE,
            "lxmf",
            "delivery",
        )
        with self.lock:
            self.reply_payloads[sequence] = {
                "destination": destination,
                "fields": message.fields,
                # Reusing the timestamp makes every application-level retry
                # produce the same signed LXMF message ID. If a proof was lost
                # after durable receipt, the Swift client can deduplicate the
                # replay and return a fresh proof.
                "timestamp": time.time(),
            }
            self.reply_retry_counts.setdefault(sequence, 0)
        self.send_reply(sequence)

    def send_reply(self, sequence):
        with self.lock:
            payload = self.reply_payloads.get(sequence)
            if payload is None or sequence in self.delivered:
                return
            self.reply_retry_due.pop(sequence, None)
        reply = LXMF.LXMessage(
            payload["destination"],
            self.source,
            f"{self.args.outbound_prefix}-{sequence}",
            "",
            fields=payload["fields"],
            desired_method=LXMF.LXMessage.DIRECT,
            include_ticket=True,
        )
        reply.timestamp = payload["timestamp"]
        reply.register_delivery_callback(
            lambda delivered, sequence=sequence: self.mark_delivered(sequence, delivered)
        )
        reply.register_failed_callback(
            lambda failed, sequence=sequence: self.mark_failed(sequence, failed)
        )
        self.router.handle_outbound(reply)
        with self.lock:
            self.reply_last_sent[sequence] = time.monotonic()
            self.reply_active_message_ids[sequence] = reply.message_id
            self.reply_watchdog_cancelled.discard(sequence)

    def mark_delivered(self, sequence, message):
        with self.lock:
            self.reply_retry_due.pop(sequence, None)
            self.reply_last_sent.pop(sequence, None)
            self.reply_active_message_ids.pop(sequence, None)
            self.reply_watchdog_cancelled.discard(sequence)
            self.failed.pop(sequence, None)
            self.delivered[sequence] = {
                "message_id": message.message_id.hex(),
                "delivered_at": time.time(),
                "attempts": int(message.delivery_attempts),
                "application_retries": self.reply_retry_counts.get(sequence, 0),
            }
        print(
            "PYTHON_PEER_DELIVERED "
            + json.dumps(
                {
                    "sequence": sequence,
                    "message_id": message.message_id.hex(),
                    "attempts": int(message.delivery_attempts),
                },
                sort_keys=True,
            ),
            flush=True,
        )
        self.write_report("running")

    def mark_failed(self, sequence, message):
        with self.lock:
            # A watchdog-cancelled attempt can report failure after its
            # replacement has already been scheduled. Ignore that stale
            # callback so it cannot consume a second application retry.
            active_id = self.reply_active_message_ids.get(sequence)
            if active_id is None or active_id != message.message_id:
                return
            self.reply_last_sent.pop(sequence, None)
            self.reply_active_message_ids.pop(sequence, None)
            self.reply_watchdog_cancelled.discard(sequence)
            retries = self.reply_retry_counts.get(sequence, 0)
            if retries < self.args.application_retries:
                retries += 1
                self.reply_retry_counts[sequence] = retries
                self.reply_retry_due[sequence] = time.monotonic() + min(5.0, 0.5 * retries)
                permanent = False
            else:
                self.failed[sequence] = {
                    "message_id": message.message_id.hex(),
                    "failed_at": time.time(),
                    "attempts": int(message.delivery_attempts),
                    "application_retries": retries,
                }
                permanent = True
        print(
            ("PYTHON_PEER_FAILED " if permanent else "PYTHON_PEER_RETRY_SCHEDULED ")
            + json.dumps(
                {
                    "sequence": sequence,
                    "message_id": message.message_id.hex(),
                    "attempts": int(message.delivery_attempts),
                    "application_retries": retries,
                },
                sort_keys=True,
            ),
            flush=True,
        )
        self.write_report("failed" if permanent else "running")

    def write_report(self, phase):
        with self.lock:
            report = {
                "phase": phase,
                "destination": self.source.hash.hex(),
                "started_at": self.started_at,
                "updated_at": time.time(),
                "expected": self.args.count,
                "received": len(self.received),
                "delivered": len(self.delivered),
                "failed": len(self.failed),
                "received_messages": self.received,
                "delivered_messages": self.delivered,
                "failed_messages": self.failed,
                "application_retry_counts": self.reply_retry_counts,
            }
        report_path = Path(self.args.report)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = report_path.with_suffix(report_path.suffix + ".tmp")
        temporary.write_text(json.dumps(report, indent=2, sort_keys=True))
        temporary.replace(report_path)

    def run(self):
        deadline = time.monotonic() + self.args.timeout
        while not self.stop_event.wait(0.1):
            now = time.monotonic()
            with self.lock:
                due_replies = [
                    sequence
                    for sequence, due in self.reply_retry_due.items()
                    if due <= now
                ]
                overdue_replies = [
                    (sequence, self.reply_active_message_ids[sequence])
                    for sequence, sent_at in self.reply_last_sent.items()
                    if sequence not in self.delivered
                    and sequence not in self.reply_watchdog_cancelled
                    and now - sent_at >= self.args.reply_watchdog_seconds
                ]
                self.reply_watchdog_cancelled.update(
                    sequence for sequence, _ in overdue_replies
                )
            for sequence in due_replies:
                self.send_reply(sequence)
            for sequence, message_id in overdue_replies:
                print(
                    "PYTHON_PEER_WATCHDOG_CANCEL "
                    + json.dumps(
                        {"sequence": sequence, "message_id": message_id.hex()},
                        sort_keys=True,
                    ),
                    flush=True,
                )
                self.router.cancel_outbound(message_id)
                # LXMRouter.cancel_outbound() is intentionally silent and does
                # not invoke the message's failed callback. Schedule the
                # bounded application retry here instead of leaving this
                # sequence permanently absent from both delivered and failed.
                with self.lock:
                    if (
                        sequence not in self.delivered
                        and self.reply_active_message_ids.get(sequence) == message_id
                    ):
                        self.reply_last_sent.pop(sequence, None)
                        self.reply_active_message_ids.pop(sequence, None)
                        retries = self.reply_retry_counts.get(sequence, 0)
                        if retries < self.args.application_retries:
                            retries += 1
                            self.reply_retry_counts[sequence] = retries
                            self.reply_retry_due[sequence] = (
                                time.monotonic() + min(5.0, 0.5 * retries)
                            )
                        else:
                            self.failed[sequence] = {
                                "message_id": message_id.hex(),
                                "failed_at": time.time(),
                                "attempts": "watchdog",
                                "application_retries": retries,
                            }
                self.write_report("running")
            candidates = list(RNS.Transport.interfaces)
            for interface in list(candidates):
                candidates.extend(getattr(interface, "spawned_interfaces", None) or [])
            live_interfaces = []
            seen_objects = set()
            for interface in candidates:
                object_id = id(interface)
                if object_id in seen_objects:
                    continue
                seen_objects.add(object_id)
                if (
                    getattr(interface, "online", False)
                    and getattr(interface, "parent_interface", None) is not None
                ):
                    live_interfaces.append(interface)
            live_interface_names = {str(interface) for interface in live_interfaces}
            new_interfaces = live_interface_names - self.announced_interfaces
            if new_interfaces or (live_interfaces and now >= self.next_periodic_announce):
                for interface in live_interfaces:
                    # TCPServerInterface spawns receive-only children by
                    # default. This direct reference peer intentionally uses
                    # the accepted socket bidirectionally, just like an
                    # endpoint-facing local test interface.
                    interface.OUT = True
                    transmitted_before = int(getattr(interface, "txb", 0))
                    announce = self.source.announce(
                        app_data=self.router.get_announce_app_data(self.source.hash),
                        attached_interface=interface,
                        send=False,
                    )
                    announce.send()
                    print(
                        "PYTHON_PEER_ANNOUNCED "
                        + json.dumps(
                            {
                                "interface": str(interface),
                                "registered": interface in RNS.Transport.interfaces,
                                "out": bool(interface.OUT),
                                "tx_bytes_before": transmitted_before,
                                "tx_bytes_after": int(getattr(interface, "txb", 0)),
                                "raw_hex": announce.raw.hex(),
                            },
                            sort_keys=True,
                        ),
                        flush=True,
                    )
                self.announced_interfaces = live_interface_names
                self.next_periodic_announce = now + 30
            with self.lock:
                complete = (
                    len(self.received) == self.args.count
                    and len(self.delivered) == self.args.count
                    and not self.failed
                )
            if complete:
                self.write_report("complete")
                print("PYTHON_PEER_COMPLETE", flush=True)
                return 0
            if now >= deadline:
                self.write_report("timeout")
                return 1
        self.write_report("cancelled")
        return 130


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--storage", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--inbound-prefix", required=True)
    parser.add_argument("--outbound-prefix", required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--application-retries", type=int, default=4)
    parser.add_argument("--reply-watchdog-seconds", type=float, default=15.0)
    parser.add_argument("--loglevel", type=int, default=5)
    return parser.parse_args()


def main():
    args = parse_args()
    peer = Peer(args)

    def stop(_signum, _frame):
        peer.stop_event.set()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    return peer.run()


if __name__ == "__main__":
    sys.exit(main())
