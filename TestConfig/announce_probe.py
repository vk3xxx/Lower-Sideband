import sys
sys.path.insert(0, "Reticulum-Upstream")
import RNS

target = bytes.fromhex("d3be58b37347c46f9078ae2a75ed01da")
RNS.Reticulum(configdir="TestConfig", loglevel=3)
found = RNS.Transport.await_path(target, timeout=15)
identity = RNS.Identity.recall(target) if found else None
print("SWIFT_ANNOUNCE_PATH", found, flush=True)
print("SWIFT_ANNOUNCE_IDENTITY", identity.hash.hex() if identity else None, flush=True)
raise SystemExit(0 if found and identity else 2)
