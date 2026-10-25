"""Sets up RoomTwin's accounts on Supabase and points the app at them.

    python3 Accounts/setup_supabase.py

Reads from .env.local:
  SUPABASE_URL       https://<project>.supabase.co
  SUPABASE_ANON_KEY  the public "anon" / "publishable" key; it goes into the app
  SUPABASE_DB_URL    the Postgres connection string (Connect › URI), only used
                     here to apply Accounts/schema.sql. Without it, paste that
                     file into the SQL editor yourself.

Writes RoomTwin/supabase.json (git-ignored), which the app bundles: rebuild
the app afterwards. Then checks the whole round trip as a throwaway user:
sign up, save a file and a row, list, delete. Supabase must have
Authentication › Email › "Confirm email" turned off, because usernames become
placeholder addresses that can't receive mail.
"""

import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.path.join(ROOT, ".env.local")


def read_env():
    values = {}
    with open(ENV) as f:
        for line in f:
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.strip().split("=", 1)
                values[name] = value
    return values


def psql():
    for candidate in [shutil.which("psql"), "/opt/homebrew/opt/libpq/bin/psql",
                      "/opt/homebrew/opt/postgresql@14/bin/psql"]:
        if candidate and os.path.exists(candidate):
            return candidate
    sys.exit("psql not found: brew install libpq, or paste Accounts/schema.sql into the SQL editor")


def sql(db_url, *args):
    result = subprocess.run([psql(), db_url, "-v", "ON_ERROR_STOP=1", "-q", *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit("psql failed: " + result.stderr.strip()[:600]
                 + "\n(if it can't connect, use the Session pooler connection string from Connect › URI)")
    return result.stdout


def call(url, key, method, path, body=None, token=None, content_type="application/json"):
    data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(url + "/" + path, method=method, data=data, headers={
        "apikey": key, "Authorization": f"Bearer {token or key}", "Content-Type": content_type})
    try:
        with urllib.request.urlopen(request) as response:
            text = response.read().decode()
            return json.loads(text) if text else None
    except urllib.error.HTTPError as error:
        sys.exit(f"{method} {path} failed with {error.code}: {error.read().decode()[:400]}")


def main():
    env = read_env()
    url, key = env.get("SUPABASE_URL", "").rstrip("/"), env.get("SUPABASE_ANON_KEY", "")
    if not url or not key:
        sys.exit("put SUPABASE_URL and SUPABASE_ANON_KEY in .env.local first")

    if env.get("SUPABASE_DB_URL"):
        sql(env["SUPABASE_DB_URL"], "-f", os.path.join(ROOT, "Accounts", "schema.sql"))
        print("== applied Accounts/schema.sql")
    else:
        print("== no SUPABASE_DB_URL: make sure Accounts/schema.sql has been run in the SQL editor")

    with open(os.path.join(ROOT, "RoomTwin", "supabase.json"), "w") as f:
        json.dump({"url": url, "anonKey": key}, f)
    print("== wrote RoomTwin/supabase.json; rebuild the app to pick it up")

    # The round trip the app makes, as a throwaway user.
    email = f"setup-check-{uuid.uuid4().hex[:8]}@users.roomtwin.app"
    reply = call(url, key, "POST", "auth/v1/signup", {"email": email, "password": uuid.uuid4().hex,
                                                      "data": {"username": "setup-check"}})
    token = reply.get("access_token")
    if not token:
        sys.exit("signing up needs email confirmation: turn off Authentication › Sign In / Providers › "
                 "Email › Confirm email in Supabase, then run this again")
    user = reply["user"]["id"]
    folder = f"{user}/{uuid.uuid4()}"
    call(url, key, "POST", f"storage/v1/object/objects/{folder}/model.usdz", b"check", token, "model/vnd.usdz+zip")
    call(url, key, "POST", "rest/v1/objects", {"name": "setup check", "model_path": f"{folder}/model.usdz"}, token)
    rows = call(url, key, "GET", "rest/v1/objects?select=id,model_path", token=token)
    assert len(rows) == 1, rows
    call(url, key, "DELETE", f"rest/v1/objects?id=eq.{rows[0]['id']}", token=token)
    call(url, key, "DELETE", "storage/v1/object/objects", {"prefixes": [f"{folder}/model.usdz"]}, token)
    print("== sign-up, upload, save, list and delete all work")
    if env.get("SUPABASE_DB_URL"):
        sql(env["SUPABASE_DB_URL"], "-c", f"delete from auth.users where email = '{email}'")
        print("   (and the throwaway user is gone)")
    else:
        print(f"   delete the throwaway user {email} under Authentication › Users")


if __name__ == "__main__":
    main()
