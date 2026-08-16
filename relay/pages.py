"""邮件落地页：验证成功/失败/重置密码表单（移动友好，无外部依赖）。"""
from fastapi.responses import HTMLResponse

_SHELL = """<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>{title}</title>
<style>
  body {{ font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;
         background:#f6f8fa;display:flex;align-items:center;justify-content:center;
         min-height:100vh;margin:0;padding:16px; }}
  .card {{ background:#fff;border:1px solid #d0d7de;border-radius:16px;
          max-width:400px;width:100%;padding:28px;box-shadow:0 4px 20px rgba(0,0,0,.06); }}
  h1 {{ font-size:18px;color:#1f2328;margin:0 0 12px; }}
  p {{ font-size:14px;color:#57606a;line-height:1.7;margin:0 0 16px; }}
  input {{ width:100%;padding:11px 12px;border:1px solid #d0d7de;border-radius:10px;
          font-size:15px;box-sizing:border-box;margin-bottom:12px; }}
  button {{ width:100%;padding:13px;background:#1f6feb;color:#fff;border:none;
           border-radius:10px;font-size:15px;font-weight:600; }}
  .ok {{ color:#1a7f37;font-weight:600;font-size:15px; }}
  .err {{ color:#cf222e;font-weight:600;font-size:15px; }}
</style></head><body>{body}</body></html>"""


def page(title: str, body: str) -> HTMLResponse:
    return HTMLResponse(_SHELL.format(title=title, body=body))


def verify_success() -> HTMLResponse:
    return page(
        "Email verified",
        '<div class="card"><h1>✅ 邮箱验证成功</h1>'
        '<p class="ok">Your email has been verified.</p>'
        "<p>You can close this page and log in from the app.</p></div>",
    )


def verify_failed() -> HTMLResponse:
    return page(
        "Verification failed",
        '<div class="card"><h1>⚠️ 验证失败</h1>'
        '<p class="err">The verification link is invalid or has expired.</p>'
        '<p>Please resend the verification email from the app.</p></div>',
    )


def reset_invalid() -> HTMLResponse:
    return page(
        "Reset failed",
        '<div class="card"><h1>⚠️ 链接无效</h1>'
        '<p class="err">The reset link is invalid or has expired.</p>'
        '<p>Please request a new password reset.</p></div>',
    )


def reset_form(token: str) -> HTMLResponse:
    body = f"""<div class="card"><h1>重置密码</h1>
<p>Please set a new password (at least 6 characters).</p>
<input type="password" id="pw" placeholder="新密码" />
<input type="password" id="pw2" placeholder="确认密码" />
<button onclick="submitReset()">确认重置</button>
<p id="msg" style="margin-top:12px"></p>
<script>
async function submitReset() {{
  const pw = document.getElementById('pw').value;
  const pw2 = document.getElementById('pw2').value;
  const msg = document.getElementById('msg');
  if (pw.length < 6) {{ msg.className='err'; msg.textContent='密码至少 6 位'; return; }}
  if (pw !== pw2) {{ msg.className='err'; msg.textContent='两次密码不一致'; return; }}
  const r = await fetch('/api/reset-password', {{
    method: 'POST',
    headers: {{'Content-Type': 'application/json'}},
    body: JSON.stringify({{ token: '{token}', password: pw }})
  }});
  const d = await r.json();
  if (r.ok) {{ msg.className='ok'; msg.textContent='✅ 密码已重置，请返回 App 登录'; }}
  else {{ msg.className='err'; msg.textContent = d.detail || '重置失败'; }}
}}
</script></div>"""
    return page("Reset password", body)
