# With this code you can input a private key and it will output the respective public key and address (derived from the pkey)

import hashlib
import binascii

# --- CONFIGURATION ---
# The Private Key we want to find (Inside Puzzle 71 Range)
PRIVATE_KEY_HEX = "4000000000000F0000"

# --- SECP256k1 LOGIC (Pure Python to avoid pip install) ---
P = 2**256 - 2**32 - 977
Gx = 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798
Gy = 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8
B = 7

def point_add(p, q):
    if p is None: return q
    if q is None: return p
    (xp, yp), (xq, yq) = p, q
    if xp == xq and yp != yq: return None
    if xp == xq:
        m = (3 * xp * xp) * pow(2 * yp, P - 2, P)
    else:
        m = (yq - yp) * pow(xq - xp, P - 2, P)
    xr = (m * m - xp - xq) % P
    yr = (m * (xp - xr) - yp) % P
    return (xr, yr)

def point_mul(p, d):
    n = p
    q = None
    while d > 0:
        if d % 2 == 1: q = point_add(q, n)
        n = point_add(n, n)
        d //= 2
    return q

# --- ADDRESS GENERATION ---
def get_address(priv_hex):
    # 1. Private Key to Public Key Point
    priv_int = int(priv_hex, 16)
    pub_point = point_mul((Gx, Gy), priv_int)
    
    # 2. Compress the Public Key
    # Prefix 02 if y is even, 03 if odd
    prefix = '02' if pub_point[1] % 2 == 0 else '03'
    pub_hex = prefix + hex(pub_point[0])[2:].zfill(64)
    
    # 3. SHA256
    pub_bytes = binascii.unhexlify(pub_hex)
    sha256_1 = hashlib.sha256(pub_bytes).digest()
    
    # 4. RIPEMD160
    ripemd160 = hashlib.new('ripemd160')
    ripemd160.update(sha256_1)
    pub_hash = ripemd160.digest()
    
    # 5. Add Network Byte (0x00 for Mainnet)
    network_byte = b'\x00' + pub_hash
    
    # 6. Double SHA256 for Checksum
    sha256_2 = hashlib.sha256(network_byte).digest()
    sha256_3 = hashlib.sha256(sha256_2).digest()
    checksum = sha256_3[:4]
    
    # 7. Base58 Encoding
    binary_addr = network_byte + checksum
    
    # Base58 Alphabet
    alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    value = int.from_bytes(binary_addr, 'big')
    base58 = ''
    while value > 0:
        value, mod = divmod(value, 58)
        base58 = alphabet[mod] + base58
    
    # Pad with '1's for leading zero bytes
    for byte in binary_addr:
        if byte == 0: base58 = '1' + base58
        else: break
        
    return base58

# --- EXECUTION ---
address = get_address(PRIVATE_KEY_HEX)
print(f"Private Key: {PRIVATE_KEY_HEX}")
print(f"Address:     {address}")