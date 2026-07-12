import sys, time
sys.path.insert(0, "Reticulum-Upstream")
import RNS

target = bytes.fromhex("0c674b8132aaba5caededa72c37048e5")
RNS.Reticulum(configdir="TestConfig", loglevel=5)
print("REFERENCE_PATH_REQUEST", target.hex(), flush=True)
if not RNS.Transport.await_path(target, timeout=15):
    print("REFERENCE_PATH_FAILED", flush=True)
    raise SystemExit(2)
identity = RNS.Identity.recall(target)
if identity is None:
    print("REFERENCE_IDENTITY_MISSING", flush=True)
    raise SystemExit(3)
destination = RNS.Destination(identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "propagation")
print("REFERENCE_DESTINATION", destination.hexhash, flush=True)
link = RNS.Link(destination)
deadline = time.time()+20
while time.time() < deadline and link.status == RNS.Link.PENDING:
    time.sleep(0.1)
print("REFERENCE_LINK_STATUS", link.status, "ACTIVE", RNS.Link.ACTIVE, flush=True)
raise SystemExit(0 if link.status == RNS.Link.ACTIVE else 4)
