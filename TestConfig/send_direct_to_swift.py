import os, sys, time
sys.path.insert(0, "Reticulum-Upstream")
sys.path.insert(0, "LXMF-Upstream")
import RNS, LXMF

recipient_hash = bytes.fromhex("d3be58b37347c46f9078ae2a75ed01da")
RNS.Reticulum(configdir="TestConfig", loglevel=4)
storage = "TestConfig/direct-sender-storage"
os.makedirs(storage, exist_ok=True)
router = LXMF.LXMRouter(storagepath=storage)
source = router.register_delivery_identity(RNS.Identity(), display_name="Python Direct")
router.announce(source.hash)
if not RNS.Transport.await_path(recipient_hash, timeout=15):
    print("DIRECT_PATH_FAILED", flush=True); raise SystemExit(2)
recipient_identity = RNS.Identity.recall(recipient_hash)
destination = RNS.Destination(recipient_identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
message = LXMF.LXMessage(destination, source, "Hello from Python direct", "Direct interop", desired_method=LXMF.LXMessage.DIRECT)
router.handle_outbound(message)
deadline = time.time()+45
while time.time() < deadline and message.state not in (LXMF.LXMessage.DELIVERED, LXMF.LXMessage.FAILED): time.sleep(0.2)
print("DIRECT_STATE", message.state, "DELIVERED", LXMF.LXMessage.DELIVERED, "FAILED", LXMF.LXMessage.FAILED, flush=True)
raise SystemExit(0 if message.state == LXMF.LXMessage.DELIVERED else 3)
