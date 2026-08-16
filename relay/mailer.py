"""邮件发送：SMTP 可配置；未配置时打印到日志（开发模式）。"""
import logging
import os
import smtplib
from email.header import Header
from email.mime.text import MIMEText

log = logging.getLogger("relay.mail")

SMTP_HOST = os.environ.get("RELAY_SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("RELAY_SMTP_PORT", "465"))
SMTP_USER = os.environ.get("RELAY_SMTP_USER", "")
SMTP_PASS = os.environ.get("RELAY_SMTP_PASS", "")
MAIL_FROM = os.environ.get("RELAY_MAIL_FROM", SMTP_USER or "no-reply@relay.zhileai.net")
# 对外链接前缀，如 https://relay.zhileai.net
PUBLIC_BASE = os.environ.get("RELAY_PUBLIC_BASE", "https://relay.zhileai.net")


def enabled() -> bool:
    return bool(SMTP_HOST and SMTP_USER and SMTP_PASS)


def send_mail(to: str, subject: str, body: str) -> bool:
    if not enabled():
        log.warning("[mail] SMTP 未配置，邮件仅打印: to=%s subject=%s\n%s", to, subject, body)
        return False
    msg = MIMEText(body, "plain", "utf-8")
    msg["Subject"] = Header(subject, "utf-8")
    msg["From"] = MAIL_FROM
    msg["To"] = to
    try:
        if SMTP_PORT == 465:
            server = smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, timeout=15)
        else:
            server = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15)
            server.starttls()
        server.login(SMTP_USER, SMTP_PASS)
        server.sendmail(MAIL_FROM, [to], msg.as_string())
        server.quit()
        log.info("[mail] 已发送: to=%s subject=%s", to, subject)
        return True
    except Exception as e:
        log.error("[mail] 发送失败: %s", e)
        return False


def build_verify_url(token: str) -> str:
    return f"{PUBLIC_BASE}/api/verify?token={token}"


def build_reset_url(token: str) -> str:
    return f"{PUBLIC_BASE}/api/reset-password?token={token}"
