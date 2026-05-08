#!/usr/bin/env python3
"""
okta_aws_auth.py — Fetch temporary AWS credentials via Okta SAML.

Flow:
  1. Classic Okta authn API (fast, works if not OIE-restricted)
  2. Admin API session impersonation (fallback for OIE orgs)
  3. Manual SAML paste (last resort — use SAML Tracer in browser)
"""
import os
import sys
import getpass
import configparser
import urllib.parse
from html.parser import HTMLParser

try:
    import requests
    import boto3
except ImportError:
    sys.exit("Missing deps — run: pip3 install requests boto3")

# ── Config (override via env vars) ────────────────────────────────────────────
OKTA_ORG      = os.getenv("OKTA_ORG",      "https://integrator-8545897.okta.com")
OKTA_APP_URL  = os.getenv("OKTA_APP_URL",  "https://integrator-8545897.okta.com/home/integrator-8545897_oktaauroraapp_1/0oa12g6r2ll3a9Avh698/aln12g707kb8YwYpq698")
OKTA_API_TOKEN= os.getenv("OKTA_API_TOKEN","00Roc77LfH_CJFYZ9IE2CILQxCECsY42j1LcmH87Tm")
ROLE_ARN      = os.getenv("AWS_ROLE_ARN",  "arn:aws:iam::853973692277:role/aurora-readonly-role")
PRINCIPAL_ARN = os.getenv("AWS_PRINCIPAL", "arn:aws:iam::853973692277:saml-provider/aurora-okta-8a1-okta-provider")
AWS_PROFILE   = os.getenv("AWS_PROFILE",   "readonly")
AWS_REGION    = os.getenv("AWS_REGION",    "us-east-1")
SESSION_SECS  = int(os.getenv("SESSION_DURATION", "3600"))
# ─────────────────────────────────────────────────────────────────────────────


class _SAMLParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.saml_response = None

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "input":
            d = dict(attrs)
            if d.get("name") == "SAMLResponse":
                self.saml_response = d.get("value")


def _headers():
    return {
        "Authorization": f"SSWS {OKTA_API_TOKEN}",
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


def _classic_authn(username: str, password: str) -> str | None:
    """POST /api/v1/authn — works on classic Okta orgs."""
    r = requests.post(
        f"{OKTA_ORG}/api/v1/authn",
        json={"username": username, "password": password},
        headers={"Content-Type": "application/json"},
        timeout=15,
    )
    if r.status_code != 200:
        return None
    data = r.json()
    status = data.get("status")
    if status == "SUCCESS":
        return data["sessionToken"]
    if status == "MFA_REQUIRED":
        return _handle_mfa(data)
    return None


def _handle_mfa(data: dict) -> str | None:
    factors = data.get("_embedded", {}).get("factors", [])
    totp = next((f for f in factors if f["factorType"] == "token:software:totp"), None)
    push = next((f for f in factors if f["factorType"] == "push"), None)

    if push:
        print("   Okta Push sent — approve on your phone...")
        r = requests.post(
            push["_links"]["verify"]["href"],
            json={"stateToken": data["stateToken"]},
            headers={"Content-Type": "application/json"},
            timeout=60,
        )
        if r.status_code == 200 and r.json().get("status") == "SUCCESS":
            return r.json()["sessionToken"]

    if totp:
        code = input("   Enter TOTP code: ").strip()
        r = requests.post(
            totp["_links"]["verify"]["href"],
            json={"stateToken": data["stateToken"], "passCode": code},
            headers={"Content-Type": "application/json"},
            timeout=15,
        )
        if r.status_code == 200 and r.json().get("status") == "SUCCESS":
            return r.json()["sessionToken"]

    return None


def _admin_impersonate(username: str) -> str | None:
    """Use admin API token to create a session token for the user (OIE fallback)."""
    r = requests.get(
        f"{OKTA_ORG}/api/v1/users/{urllib.parse.quote(username)}",
        headers=_headers(),
        timeout=15,
    )
    if r.status_code != 200:
        print(f"   Could not fetch user from Okta API: {r.status_code}")
        return None

    data = r.json()
    user_id = (data[0]["id"] if isinstance(data, list) else data["id"])
    r = requests.post(
        f"{OKTA_ORG}/api/v1/users/{user_id}/sessions",
        headers=_headers(),
        json={},
        timeout=15,
    )
    if r.status_code == 200:
        payload = r.json()
        return payload.get("sessionToken") or payload.get("id")

    print(f"   Admin session creation returned {r.status_code}: {r.text[:200]}")
    return None


def _saml_from_session(session_token: str) -> str | None:
    """Exchange session token for a session cookie then hit the app SSO URL."""
    session = requests.Session()

    # sessionCookieRedirect sets the session cookie and redirects to the app
    redirect_url = urllib.parse.quote(OKTA_APP_URL, safe="")
    url = f"{OKTA_ORG}/login/sessionCookieRedirect?token={session_token}&redirectUrl={redirect_url}"

    r = session.get(url, allow_redirects=True, timeout=20)
    p = _SAMLParser()
    p.feed(r.text)
    return p.saml_response


def _ensure_base64(saml: str) -> str:
    """Normalise SAMLResponse to a clean base64 string AWS will accept."""
    import base64, urllib.parse

    s = saml.strip()

    # Strip leading field name if user copied "SAMLResponse=<value>"
    if s.lower().startswith("samlresponse="):
        s = s[len("samlresponse="):]

    # URL-decode in case SAML Tracer gave us the form-encoded value
    s = urllib.parse.unquote(s).strip()

    print(f"\n[DEBUG] Length : {len(s)} chars")
    print(f"[DEBUG] Starts with : {s[:40]!r}")

    if s.lstrip().startswith("<"):
        print("[WARN]  Got decoded XML — this will FAIL because the signature")
        print("        covers the original bytes. Copy from the Parameters tab")
        print("        in SAML Tracer, not the SAML tab.")
        sys.exit(1)

    # Raw base64 — strip display whitespace, fix padding
    print("[DEBUG] Got base64 — good.")
    s = "".join(s.split())
    pad = (4 - len(s) % 4) % 4
    return s + "=" * pad


def _inspect_saml(b64: str):
    """Decode and print key SAML attributes for debugging."""
    import base64, re
    xml = base64.b64decode(b64 + "==").decode("utf-8", errors="replace")
    role  = re.findall(r'Attributes/Role"[^>]*>.*?<.*?>(.*?)</', xml, re.DOTALL)
    rname = re.findall(r'Attributes/RoleSessionName"[^>]*>.*?<.*?>(.*?)</', xml, re.DOTALL)
    dest  = re.findall(r'Destination="([^"]+)"', xml)
    print(f"\n[SAML] Destination    : {dest[0] if dest else 'NOT FOUND'}")
    print(f"[SAML] RoleSessionName: {rname[0].strip() if rname else 'NOT FOUND'}")
    print(f"[SAML] Role value     : {role[0].strip() if role else 'NOT FOUND'}")
    if role:
        parts = role[0].strip().split(",")
        if len(parts) < 2:
            print("[WARN]  Role attribute is missing role ARN or provider ARN — must be 'role_arn,provider_arn'")
        else:
            print(f"[SAML] Role ARN       : {parts[0].strip()}")
            print(f"[SAML] Provider ARN   : {parts[1].strip()}")

    # Check assertion signature presence
    assertion_start = xml.find("Assertion ")
    if assertion_start == -1:
        print("[WARN]  No Assertion element found in SAML")
    else:
        assertion_block = xml[assertion_start:assertion_start + 2000]
        if "Signature" in assertion_block:
            print("[SAML] Assertion signature : PRESENT")
        else:
            print("[WARN]  Assertion signature : MISSING — Okta is not signing the assertion")


def _assume_role(saml_assertion: str) -> dict:
    sts = boto3.client("sts", region_name=AWS_REGION)
    resp = sts.assume_role_with_saml(
        RoleArn=ROLE_ARN,
        PrincipalArn=PRINCIPAL_ARN,
        SAMLAssertion=saml_assertion,
        DurationSeconds=SESSION_SECS,
    )
    return resp["Credentials"]


def _write_creds(creds: dict):
    path = os.path.expanduser("~/.aws/credentials")
    cfg = configparser.ConfigParser()
    if os.path.exists(path):
        cfg.read(path)
    cfg[AWS_PROFILE] = {
        "aws_access_key_id":     creds["AccessKeyId"],
        "aws_secret_access_key": creds["SecretAccessKey"],
        "aws_session_token":     creds["SessionToken"],
        "region":                AWS_REGION,
    }
    os.makedirs(os.path.expanduser("~/.aws"), exist_ok=True)
    with open(path, "w") as f:
        cfg.write(f)
    print(f"\n[OK] Credentials saved to [{AWS_PROFILE}] in {path}")
    print(f"     Expires : {creds['Expiration']}")
    print(f"\nVerify with: aws sts get-caller-identity --profile {AWS_PROFILE}")


def _get_saml_via_playwright(username: str, password: str, mfa_code: str = "") -> str | None:
    """Automate browser login and intercept the SAML POST to AWS."""
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("   Playwright not installed — run: pip3 install playwright && playwright install chromium")
        return None

    import urllib.parse
    saml_response = None

    print("   Launching headless browser...")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(headless=True)
        page = browser.new_page()

        # Intercept the SAML POST before it reaches AWS
        def intercept(route):
            nonlocal saml_response
            body = route.request.post_data or ""
            params = urllib.parse.parse_qs(body)
            if "SAMLResponse" in params:
                saml_response = params["SAMLResponse"][0]
                print("   SAML assertion captured.")
            route.abort()

        page.route("https://signin.aws.amazon.com/saml", intercept)

        def js_click(text):
            """Click any element whose text contains `text` via JavaScript."""
            page.evaluate(f"""
                const all = [...document.querySelectorAll('button, a, input[type=submit]')];
                const el = all.find(e => e.textContent.includes('{text}') || e.value === '{text}');
                if (el) el.click();
            """)

        def js_click_totp_select():
            """Click the Select button next to the TOTP/Enter-a-code authenticator row."""
            clicked = page.evaluate("""
                () => {
                    const rows = [...document.querySelectorAll('*')];
                    // Look for a container that mentions 'code' or 'totp' or 'Google' or 'Authenticator'
                    const keywords = ['enter a code', 'google authenticator', 'totp', 'authenticator app'];
                    for (const el of rows) {
                        const text = el.textContent.toLowerCase();
                        if (keywords.some(k => text.includes(k)) && text.length < 200) {
                            // Find a button/link inside or nearby
                            const btn = el.querySelector('button, a') ||
                                        el.closest('li, div')?.querySelector('button, a');
                            if (btn) { btn.click(); return btn.textContent.trim(); }
                        }
                    }
                    // Fallback: click first visible Select button
                    const all = [...document.querySelectorAll('button, a')];
                    const sel = all.find(e => e.textContent.trim() === 'Select');
                    if (sel) { sel.click(); return 'fallback:' + sel.textContent.trim(); }
                    return null;
                }
            """)
            print(f"   Authenticator click result: {clicked}")

        try:
            page.goto(OKTA_APP_URL, timeout=20000)
            page.wait_for_timeout(3000)

            # Step 1 — username
            page.fill('input[name="identifier"]', username)
            js_click("Next")
            page.wait_for_timeout(3000)
            page.screenshot(path="/tmp/okta_step1.png")

            # Step 2 — select TOTP authenticator (not Okta Verify push)
            js_click_totp_select()
            page.wait_for_timeout(3000)
            page.screenshot(path="/tmp/okta_step2.png")
            print("   Authenticator selected — check /tmp/okta_step2.png")

            # Step 3 — TOTP input
            page.wait_for_timeout(1000)
            inputs = page.evaluate("() => [...document.querySelectorAll('input')].map(i => ({type: i.type, name: i.name, visible: i.offsetParent !== null}))")
            print(f"   Visible inputs: {inputs}")

            totp_sel = 'input[name="credentials.totp"], input[name="credentials.passcode"], input[type="tel"], input[name="totp"], input[name="answer"]'
            try:
                page.wait_for_selector(totp_sel, timeout=8000)
                code = mfa_code or input("   Enter MFA code: ").strip()
                page.locator(totp_sel).first.fill(code)
                page.wait_for_timeout(500)
                page.locator(totp_sel).first.press("Enter")
                print("   TOTP submitted — waiting for next step...")
            except Exception as e:
                print(f"   MFA input error: {e}")
                page.screenshot(path="/tmp/okta_debug.png")

            # Step 4 — Okta may ask for password after TOTP
            page.wait_for_timeout(3000)
            try:
                pwd_sel = 'input[type="password"], input[name="credentials.password"]'
                if page.locator(pwd_sel).count() > 0:
                    print("   Password step detected — filling password...")
                    page.locator(pwd_sel).first.fill(password)
                    page.wait_for_timeout(300)
                    page.locator(pwd_sel).first.press("Enter")
                    print("   Password submitted — waiting for SAML...")
            except Exception as e:
                print(f"   Password step error: {e}")

            # Wait for SAML interception (up to 20s)
            for _ in range(20):
                if saml_response:
                    break
                page.wait_for_timeout(1000)

            if not saml_response:
                page.screenshot(path="/tmp/okta_debug.png")
                print("   Screenshot saved to /tmp/okta_debug.png — open to see where it's stuck")

        except Exception as e:
            print(f"   Browser automation error: {e}")
            try:
                page.screenshot(path="/tmp/okta_debug.png")
                print("   Screenshot saved to /tmp/okta_debug.png")
            except Exception:
                pass
        finally:
            browser.close()

    return saml_response


def _read_saml_from_clipboard_or_file() -> str | None:
    """Read SAMLResponse from macOS clipboard, falling back to /tmp/saml.txt."""
    try:
        import subprocess
        result = subprocess.run(["pbpaste"], capture_output=True, text=True, timeout=5)
        data = result.stdout.strip()
        if data and len(data) > 100:
            print("      Read from clipboard.")
            return data
    except Exception:
        pass

    path = "/tmp/saml.txt"
    if os.path.exists(path):
        with open(path) as f:
            data = f.read().strip()
        if data:
            print(f"      Read from {path}.")
            return data

    print("      Nothing found in clipboard or /tmp/saml.txt.")
    return None


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Okta → AWS credential fetcher")
    parser.add_argument("--username", "-u", default=os.getenv("OKTA_USERNAME", ""))
    parser.add_argument("--password", "-p", default=os.getenv("OKTA_PASSWORD", ""))
    parser.add_argument("--mfa", "-m", default=os.getenv("OKTA_MFA", ""), help="TOTP code (skips interactive prompt)")
    args = parser.parse_args()

    print("=" * 50)
    print("  Okta → AWS Credential Fetcher")
    print("=" * 50)

    username = args.username or input("\nOkta username: ").strip()
    password = args.password or getpass.getpass("Okta password: ")

    saml_assertion = None

    # ── Playwright headless browser ───────────────────────────────────────────
    print("\n[1/2] Headless browser (Playwright)...")
    saml_assertion = _get_saml_via_playwright(username, password, mfa_code=args.mfa)

    # ── Manual clipboard fallback ─────────────────────────────────────────────
    if not saml_assertion:
        print("\n[2/2] Manual fallback:")
        print(f"      1. Open: {OKTA_APP_URL}")
        print(f"      2. Log in, open DevTools → Network → find POST to signin.aws.amazon.com")
        print(f"      3. Copy SAMLResponse value to clipboard")
        print()
        input("Press Enter once copied...")
        saml_assertion = _read_saml_from_clipboard_or_file()

    if not saml_assertion:
        sys.exit("[ERROR] No SAML assertion — cannot continue.")

    # ── Assume role + write creds ─────────────────────────────────────────────
    b64 = _ensure_base64(saml_assertion)
    _inspect_saml(b64)

    print("\nAssuming AWS role...")
    try:
        creds = _assume_role(b64)
        _write_creds(creds)
    except Exception as e:
        sys.exit(f"[ERROR] AssumeRoleWithSAML failed: {e}")


if __name__ == "__main__":
    main()
