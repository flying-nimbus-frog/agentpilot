import os
import secrets
import sqlite3
import time
import uuid

DB_PATH = os.environ.get("RELAY_DB", os.path.join(os.path.dirname(__file__), "..", "relay.db"))


def _conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db() -> None:
    with _conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                email TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                salt TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id),
                name TEXT NOT NULL,
                token TEXT NOT NULL,
                version TEXT,
                created_at INTEGER NOT NULL,
                last_seen INTEGER NOT NULL
            );
            """
        )


def create_user(email: str, password_hash: str, salt: str) -> dict:
    uid = f"usr_{uuid.uuid4().hex[:12]}"
    with _conn() as conn:
        try:
            conn.execute(
                "INSERT INTO users (id, email, password_hash, salt, created_at) VALUES (?,?,?,?,?)",
                (uid, email, password_hash, salt, int(time.time() * 1000)),
            )
        except sqlite3.IntegrityError:
            return None
    return {"id": uid, "email": email}


def get_user_by_email(email: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
    return dict(row) if row else None


def get_user(user_id: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    return dict(row) if row else None


def register_device(user_id: str, name: str) -> dict:
    dev_id = f"dev_{uuid.uuid4().hex[:12]}"
    token = f"dt_{secrets.token_urlsafe(32)}"
    now = int(time.time() * 1000)
    with _conn() as conn:
        conn.execute(
            "INSERT INTO devices (id, user_id, name, token, created_at, last_seen) VALUES (?,?,?,?,?,?)",
            (dev_id, user_id, name, token, now, now),
        )
    return {"id": dev_id, "name": name, "token": token}


def list_devices(user_id: str) -> list[dict]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM devices WHERE user_id=? ORDER BY created_at", (user_id,)
        ).fetchall()
    return [dict(r) for r in rows]


def get_device_by_token(token: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM devices WHERE token=?", (token,)).fetchone()
    return dict(row) if row else None


def get_device(device_id: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
    return dict(row) if row else None


def touch_device(device_id: str, version: str | None = None) -> None:
    with _conn() as conn:
        conn.execute(
            "UPDATE devices SET last_seen=?, version=COALESCE(?, version) WHERE id=?",
            (int(time.time() * 1000), version, device_id),
        )


def delete_device(user_id: str, device_id: str) -> bool:
    with _conn() as conn:
        cur = conn.execute(
            "DELETE FROM devices WHERE id=? AND user_id=?", (device_id, user_id)
        )
        return cur.rowcount > 0
