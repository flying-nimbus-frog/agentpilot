import hashlib
import hmac
import os
import secrets
import time

import jwt

ALGO = "HS256"
JWT_SECRET = os.environ.get("RELAY_JWT_SECRET", "dev-secret-change-me")
JWT_TTL_DAYS = 30
PBKDF2_ROUNDS = 100_000


def hash_password(password: str) -> tuple[str, str]:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode(), bytes.fromhex(salt), PBKDF2_ROUNDS
    )
    return digest.hex(), salt


def verify_password(password: str, salt: str, expected: str) -> bool:
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode(), bytes.fromhex(salt), PBKDF2_ROUNDS
    )
    return hmac.compare_digest(digest.hex(), expected)


def create_token(user_id: str) -> str:
    payload = {
        "sub": user_id,
        "exp": int(time.time()) + JWT_TTL_DAYS * 86400,
        "iat": int(time.time()),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=ALGO)


def decode_token(token: str) -> str | None:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[ALGO])
        return payload.get("sub")
    except jwt.PyJWTError:
        return None
