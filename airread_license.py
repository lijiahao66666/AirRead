"""
AirRead 卡密生成/校验脚本（Ed25519）

目的
- 你离线用私钥材料（privateSeedB64）生成卡密
- App 端只内置公钥（publicKeyB64）用于验签，无法反推出私钥

重要安全原则
- privateSeedB64 = 私钥材料，必须严格保密（不要进仓库、不要发给任何人、不要打进 App）
- publicKeyB64 = 公钥，可以放进 App（它本来就不需要保密）
- 卡密格式：AR1.<payloadBase64Url>.<signatureBase64Url>
  payload 内含 iat/exp/days/nonce；nonce 是随机数，所以同样 1 天每次生成都不同

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
   python airread_license.py verify --pub "<publicKeyB64>" --code "<AR1....>"


"""

import argparse
import base64
import json
import secrets
import time

from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

PREFIX = "AR1"
ALLOWED_DAYS = {1, 7, 15, 30, 60, 180, 360}


def b64url_nopad_encode(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("utf-8").rstrip("=")


def b64url_nopad_decode(s: str) -> bytes:
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


def generate_license(private_seed_b64: str, days: int, now_ms: int | None = None) -> str:
    return generate_signed_license(private_seed_b64, days, now_ms=now_ms)


def generate_signed_license(private_seed_b64: str, days: int, now_ms: int | None = None) -> str:
    if days not in ALLOWED_DAYS:
        raise ValueError(f"days not supported: {days}")

    seed = base64.b64decode(private_seed_b64.strip())
    if len(seed) != 32:
        raise ValueError("privateSeedB64 must be 32 bytes after base64 decoding")

    sk = Ed25519PrivateKey.from_private_bytes(seed)

    if now_ms is None:
        now_ms = int(time.time() * 1000)

    iat = now_ms
    exp = iat + 600 * 1000
    nonce = b64url_nopad_encode(secrets.token_bytes(12))

    payload = {
        "v": 1,
        "iat": iat,
        "exp": exp,
        "days": days,
        "nonce": nonce,
    }
    payload_bytes = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    sig = sk.sign(payload_bytes)

    p = b64url_nopad_encode(payload_bytes)
    s = b64url_nopad_encode(sig)
    return f"{PREFIX}.{p}.{s}"


def generate_short_license(days: int) -> str:
    raise ValueError("short license is disabled")


def verify_and_parse(code: str, public_key_b64: str) -> dict:
    code = code.strip()
    if not code:
        raise ValueError("empty code")

    if not code.startswith(PREFIX):
        raise ValueError("prefix/version not supported")

    parts = code.split(".")
    if len(parts) != 3:
        raise ValueError("format error")
    if parts[0] != PREFIX:
        raise ValueError("prefix/version not supported")

    payload_bytes = b64url_nopad_decode(parts[1])
    sig_bytes = b64url_nopad_decode(parts[2])

    payload = json.loads(payload_bytes.decode("utf-8"))
    iat = int(payload.get("iat", 0))
    exp = int(payload.get("exp", 0))
    days = int(payload.get("days", 0))
    nonce = str(payload.get("nonce", ""))

    if iat <= 0 or exp <= 0 or not nonce:
        raise ValueError("payload missing fields")
    if days not in ALLOWED_DAYS:
        raise ValueError("days not supported")
    if exp <= int(time.time() * 1000):
        raise ValueError("expired")

    pk_bytes = base64.b64decode(public_key_b64.strip())
    if len(pk_bytes) != 32:
        raise ValueError("publicKeyB64 must be 32 bytes after base64 decoding")
    pk = Ed25519PublicKey.from_public_bytes(pk_bytes)

    pk.verify(sig_bytes, payload_bytes)
    return payload


def main():
    epilog = """
示例：
  python airread_license.py gen-keys --out keys.json
  python airread_license.py gen --seed "<privateSeedB64>" --days 1
  python airread_license.py verify --pub "<publicKeyB64>" --code "<AR1....>"
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
    sp.add_argument("--now-ms", type=int, default=0, help="optional fixed now (ms)")
    # short code intentionally disabled

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
        now_ms = args.now_ms if args.now_ms > 0 else None
        code = generate_signed_license(args.seed, args.days, now_ms=now_ms)
        print(code)
        return

    if args.cmd == "verify":
        payload = verify_and_parse(args.code, args.pub)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return


if __name__ == "__main__":
    main()
