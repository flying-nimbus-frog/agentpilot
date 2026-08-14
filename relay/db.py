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
                pending_token TEXT,
                version TEXT,
                status TEXT NOT NULL DEFAULT 'active',
                pairing_code TEXT,
                pairing_expires INTEGER,
                created_at INTEGER NOT NULL,
                last_seen INTEGER NOT NULL
            );
            """
        )
        # 旧库迁移：补充 status/pairing 字段（老设备视为已激活）
        cols = {r[1] for r in conn.execute("PRAGMA table_info(devices)")}
        if "status" not in cols:
            conn.execute("ALTER TABLE devices ADD COLUMN status TEXT NOT NULL DEFAULT 'active'")
        if "pending_token" not in cols:
            conn.execute("ALTER TABLE devices ADD COLUMN pending_token TEXT")
        if "pairing_code" not in cols:
            conn.execute("ALTER TABLE devices ADD COLUMN pairing_code TEXT")
        if "pairing_expires" not in cols:
            conn.execute("ALTER TABLE devices ADD COLUMN pairing_expires INTEGER")


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


def create_pending_device(user_id: str, name: str, pairing_code: str, ttl_sec: int = 600) -> dict:
    """创建待配对设备，返回 pendingID 与临时 pendingToken。"""
    dev_id = f"dev_{uuid.uuid4().hex[:12]}"
    pending_token = f"pt_{secrets.token_urlsafe(32)}"
    now = int(time.time() * 1000)
    with _conn() as conn:
        conn.execute(
            """INSERT INTO devices (id, user_id, name, token, pending_token, status, pairing_code, pairing_expires, created_at, last_seen)
               VALUES (?,?,?,?,?,?,?,?,?,?)""",
            (dev_id, user_id, name, pending_token, pending_token, "pending", pairing_code,
             now + ttl_sec * 1000, now, now),
        )
    return {"id": dev_id, "name": name, "pendingToken": pending_token, "pairingCode": pairing_code}


def activate_pending_device(device_id: str, user_id: str) -> dict | None:
    """手机确认配对：生成正式设备令牌，返回 (deviceToken) 或 None。"""
    with _conn() as conn:
        row = conn.execute(
            "SELECT * FROM devices WHERE id=? AND user_id=?", (device_id, user_id)
        ).fetchone()
        if not row or row["status"] != "pending":
            return None
        token = f"dt_{secrets.token_urlsafe(32)}"
        now = int(time.time() * 1000)
        conn.execute(
            "UPDATE devices SET status='active', token=?, pairing_code=NULL, pairing_expires=NULL, last_seen=? WHERE id=?",
            (token, now, device_id),
        )
    return {"deviceID": device_id, "deviceToken": token}


def get_pending_device(device_id: str, user_id: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute(
            "SELECT * FROM devices WHERE id=? AND user_id=? AND status='pending'",
            (device_id, user_id),
        ).fetchone()
    return dict(row) if row else None


def list_pending_devices(user_id: str) -> list[dict]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM devices WHERE user_id=? AND status='pending'", (user_id,)
        ).fetchall()
    return [dict(r) for r in rows]


def list_devices(user_id: str) -> list[dict]:
    with _conn() as conn:
        rows = conn.execute(
            "SELECT * FROM devices WHERE user_id=? ORDER BY created_at", (user_id,)
        ).fetchall()
    return [dict(r) for r in rows]


def get_device_by_token(token: str) -> dict | None:
    with _conn() as conn:
        row = conn.execute(
            "SELECT * FROM devices WHERE token=? AND status='active'", (token,)
        ).fetchone()
    return dict(row) if row else None


def get_pending_device_by_token(token: str) -> dict | None:
    """pendingToken 有效期内可查配对状态；激活后可凭 pendingToken 取一次正式令牌。"""
    with _conn() as conn:
        row = conn.execute(
            "SELECT * FROM devices WHERE (token=? OR pending_token=?) AND status='pending'",
            (token, token),
        ).fetchone()
        if row:
            return dict(row)
        row = conn.execute(
            "SELECT * FROM devices WHERE pending_token=? AND status='active'",
            (token,),
        ).fetchone()
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
