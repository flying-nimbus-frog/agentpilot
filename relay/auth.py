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


def create_token(user_id: str, session_version: int = 0, purpose: str = "auth") -> str:
    payload = {
        "sub": user_id,
        "exp": int(time.time()) + JWT_TTL_DAYS * 86400,
        "iat": int(time.time()),
        "ver": session_version,
        "purpose": purpose,
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=ALGO)


def decode_token(token: str) -> dict | None:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[ALGO])
    except jwt.PyJWTError:
        return None


def create_one_time_token(user_id: str, purpose: str, ttl_sec: int) -> str:
    """一次性令牌（邮箱验证/密码重置），短时效。"""
    payload = {
        "sub": user_id,
        "exp": int(time.time()) + ttl_sec,
        "iat": int(time.time()),
        "purpose": purpose,
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=ALGO)


def verify_one_time_token(token: str, purpose: str) -> str | None:
    """校验一次性令牌，返回 user_id 或 None。"""
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[ALGO])
    except jwt.PyJWTError:
        return None
    if payload.get("purpose") != purpose:
        return None
    return payload.get("sub")
