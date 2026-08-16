"""本地 .env 加载器：main.py 同目录存在 .env 时自动读入环境变量（不覆盖已设置的值）。
保持零依赖，格式兼容 docker-compose 的 .env。
"""
import logging
import os
from pathlib import Path

log = logging.getLogger("relay.dotenv")


def load_dotenv() -> None:
    env_file = Path(__file__).resolve().parent / ".env"
    if not env_file.exists():
        return
    count = 0
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value
            count += 1
    if count:
        log.info("已从本地 .env 加载 %d 个配置项", count)
