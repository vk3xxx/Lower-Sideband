import os, sys, time
sys.path.insert(0, "Reticulum-Upstream")
sys.path.insert(0, "LXMF-Upstream")
import RNS, LXMF

recipient_hash = bytes.fromhex("d3be58b37347c46f9078ae2a75ed01da")
node_hash = bytes.fromhex("0c674b8132aaba5caededa72c37048e5")
RNS.Reticulum(configdir="TestConfig", loglevel=4)
storage = "TestConfig/sender-storage"
os.makedirs(storage, exist_ok=True)
router = LXMF.LXMRouter(storagepath=storage)
source = router.register_delivery_identity(RNS.Identity(), display_name="Python Interop")
router.announce(source.hash)
for target in (recipient_hash, node_hash):
    if not RNS.Transport.await_path(target, timeout=15):
        print("SEND_PATH_FAILED", target.hex(), flush=True); raise SystemExit(2)
recipient_identity = RNS.Identity.recall(recipient_hash)
destination = RNS.Destination(recipient_identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
router.set_outbound_propagation_node(node_hash)
message = LXMF.LXMessage(destination, source, "Hello from Python propagation", "Interop test", desired_method=LXMF.LXMessage.PROPAGATED)
router.handle_outbound(message)
deadline = time.time()+60
while time.time() < deadline and message.state not in (LXMF.LXMessage.SENT, LXMF.LXMessage.DELIVERED, LXMF.LXMessage.FAILED):
    time.sleep(0.2)
print("SEND_STATE", message.state, "SENT", LXMF.LXMessage.SENT, "FAILED", LXMF.LXMessage.FAILED, flush=True)
raise SystemExit(0 if message.state == LXMF.LXMessage.SENT else 3)
