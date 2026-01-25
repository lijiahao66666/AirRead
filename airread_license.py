"""
AirRead 卡密生成/校验脚本（签名版）

目的
- 你离线用私钥材料（privateSeedB64）生成卡密
- App 端只内置公钥（publicKeyB64）用于验签

卡密格式
- A3 + Base64Url(payload + signature)
- payload = daysIndex(1字节) + nonce(4字节)

安装依赖
- Python 3.9+
- pip install cryptography

常用命令
1) 生成一对密钥（只需一次）
   python airread_license.py gen-keys --out keys.json
   输出 keys.json：
     - privateSeedB64：保密保存（发卡端/你个人电脑）
     - publicKeyB64：给 App 构建注入

2) 生成卡密（1/7/15/30/60/180/360 天）
   python airread_license.py gen --seed "<privateSeedB64>" --days 1
   python airread_license.py gen --seed "<privateSeedB64>" --days 30

3) 校验卡密（调试用）
   python airread_license.py verify --pub "<publicKeyB64>" --code "<A3...>"
"""

import argparse
import base64
import json
import secrets

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

PREFIX = "A3"
ALLOWED_DAYS = {1, 7, 15, 30, 60, 180, 360}
DAYS_BY_INDEX = [1, 7, 15, 30, 60, 180, 360]
NONCE_LEN = 4
SIG_LEN = 64


def _b64url_nopad_encode(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("utf-8").rstrip("=")


def _b64url_nopad_decode(s: str) -> bytes:
    pad = "=" * ((4 - (len(s) % 4)) % 4)
    return base64.urlsafe_b64decode((s + pad).encode("utf-8"))


def gen_keypair_seed() -> tuple[str, str]:
    seed = secrets.token_bytes(32)
    sk = Ed25519PrivateKey.from_private_bytes(seed)
    pk = sk.public_key()
    public_key_b64 = base64.b64encode(
        pk.public_bytes(Encoding.Raw, PublicFormat.Raw)
    ).decode("utf-8")
    private_seed_b64 = base64.b64encode(seed).decode("utf-8")
    return private_seed_b64, public_key_b64


def generate_license(private_seed_b64: str, days: int) -> str:
    return generate_signed_license(private_seed_b64, days)


def generate_signed_license(private_seed_b64: str, days: int) -> str:
    if days not in ALLOWED_DAYS:
        raise ValueError(f"days not supported: {days}")
    day_index = DAYS_BY_INDEX.index(days)
    seed = base64.b64decode(private_seed_b64.strip())
    if len(seed) != 32:
        raise ValueError("privateSeedB64 must be 32 bytes after base64 decoding")
    sk = Ed25519PrivateKey.from_private_bytes(seed)
    payload = bytes([day_index]) + secrets.token_bytes(NONCE_LEN)
    sig = sk.sign(payload)
    code = _b64url_nopad_encode(payload + sig)
    return f"{PREFIX}{code}"


def verify_and_parse(code: str, public_key_b64: str) -> dict:
    code = code.strip()
    if not code:
        raise ValueError("empty code")
    if not code.startswith(PREFIX):
        raise ValueError("prefix/version not supported")
    body = code[len(PREFIX) :]
    if not body:
        raise ValueError("format error")
    data = _b64url_nopad_decode(body)
    payload_len = 1 + NONCE_LEN
    expected_len = payload_len + SIG_LEN
    if len(data) != expected_len:
        raise ValueError("format error")
    payload = data[:payload_len]
    sig = data[payload_len:]
    day_index = payload[0]
    if day_index >= len(DAYS_BY_INDEX):
        raise ValueError("days not supported")
    pk_bytes = base64.b64decode(public_key_b64.strip())
    if len(pk_bytes) != 32:
        raise ValueError("publicKeyB64 must be 32 bytes after base64 decoding")
    pk = Ed25519PublicKey.from_public_bytes(pk_bytes)
    pk.verify(sig, payload)
    return {"days": DAYS_BY_INDEX[day_index]}


def main():
    epilog = """
示例：
  python airread_license.py gen-keys --out keys.json
  python airread_license.py gen --seed "<privateSeedB64>" --days 1
  python airread_license.py verify --pub "<publicKeyB64>" --code "<A3...>"
"""
    ap = argparse.ArgumentParser(
        description="AirRead license generator/verifier (Ed25519)",
        epilog=epilog,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("gen-keys", help="generate one Ed25519 seed/public key pair")
    sp.add_argument("--out", default="", help="optional output json path")

    sp = sub.add_parser("gen", help="generate license code")
    sp.add_argument("--seed", required=True, help="privateSeedB64 (keep secret)")
    sp.add_argument("--days", type=int, required=True, choices=sorted(ALLOWED_DAYS))

    sp = sub.add_parser("verify", help="verify and parse license code")
    sp.add_argument("--pub", required=True, help="publicKeyB64")
    sp.add_argument("--code", required=True, help="license code")

    args = ap.parse_args()

    if args.cmd == "gen-keys":
        seed_b64, pub_b64 = gen_keypair_seed()
        obj = {"privateSeedB64": seed_b64, "publicKeyB64": pub_b64}
        if args.out:
            with open(args.out, "w", encoding="utf-8") as f:
                json.dump(obj, f, ensure_ascii=False, indent=2)
        print(json.dumps(obj, ensure_ascii=False, indent=2))
        return

    if args.cmd == "gen":
        code = generate_signed_license(args.seed, args.days)
        print(code)
        return

    if args.cmd == "verify":
        payload = verify_and_parse(args.code, args.pub)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return


if __name__ == "__main__":
    main()
