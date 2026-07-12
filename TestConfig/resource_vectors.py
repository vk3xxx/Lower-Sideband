import sys
sys.path.insert(0, "Reticulum-Upstream")
from RNS.vendor import umsgpack

resource_hash = bytes(range(32))
random_hash = bytes([1, 2, 3, 4])
original_hash = bytes(range(32, 64))
part_hashes = bytes.fromhex("aabbccdd11223344")
advertisement = {"t": 900, "d": 880, "n": 2, "h": resource_hash, "r": random_hash, "o": original_hash, "i": 1, "l": 1, "q": None, "f": 0x21, "m": part_hashes}

print("ADVERTISEMENT", umsgpack.packb(advertisement).hex())
print("PART_REQUEST", (b"\x00" + resource_hash + part_hashes).hex())
print("HASHMAP_UPDATE", (resource_hash + umsgpack.packb([1, part_hashes])).hex())
