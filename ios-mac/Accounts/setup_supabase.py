"""Sets up RoomTwin's accounts on Supabase and points the app at them.

    python3 Accounts/setup_supabase.py

Reads from .env.local:
  SUPABASE_URL       https://<project>.supabase.co
  SUPABASE_ANON_KEY  the public "anon" / "publishable" key; it goes into the app
  SUPABASE_DB_URL    the Postgres connection string (Connect › URI), only used
                     here to apply Accounts/schema.sql. Without it, paste that
                     file into the SQL editor yourself. The direct address is
                     IPv6-only on newer projects; where that doesn't resolve,
                     the project's IPv4 session pooler is found and saved as
                     SUPABASE_DB_POOLER.

Writes RoomTwin/supabase.json (git-ignored), which the app bundles: rebuild
the app afterwards. Then checks the whole round trip as a throwaway user:
sign up, save a file and a row, list, delete. Supabase must have
Authentication › Email › "Confirm email" turned off, because usernames become
placeholder addresses that can't receive mail.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.path.join(os.path.dirname(ROOT), ".env.local")  # at the top of the repo


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


POOLER_REGIONS = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "sa-east-1", "eu-west-1",
                  "eu-west-2", "eu-west-3", "eu-central-1", "eu-central-2", "eu-north-1", "ap-south-1",
                  "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ap-northeast-2"]


def connection(db_url):
    """The connection string's parts as psql's environment variables. Split by
    hand, as passwords often hold characters like @ that a URL should escape."""
    rest = db_url.split("://", 1)[1]
    credentials, place = rest.rsplit("@", 1)
    user, password = credentials.split(":", 1)
    address, _, database = place.partition("/")
    host, _, port = address.partition(":")
    env = {**os.environ, "PGUSER": urllib.parse.unquote(user), "PGPASSWORD": urllib.parse.unquote(password),
           "PGHOST": host, "PGPORT": port or "5432", "PGDATABASE": database.split("?")[0] or "postgres",
           "PGSSLMODE": "require", "PGCONNECT_TIMEOUT": "8"}
    if host.startswith("db.") and not resolves(host):
        ref = host.split(".")[1]
        env["PGUSER"] = f"postgres.{ref}"
        env["PGHOST"] = pooler(env)
        env["PGPORT"] = "5432"
    return env


def resolves(host):
    try:
        socket.getaddrinfo(host, 5432, socket.AF_INET)
        return True
    except socket.gaierror:
        return False


def pooler(env):
    """The project's session pooler: saved in .env.local, or found by asking
    each region's. A wrong region turns the user away before any password
    exchange, and SCRAM never sends the password itself."""
    saved = read_env().get("SUPABASE_DB_POOLER")
    if saved:
        return saved
    for prefix in ["aws-0", "aws-1"]:
        for region in POOLER_REGIONS:
            host = f"{prefix}-{region}.pooler.supabase.com"
            result = subprocess.run([psql(), "-tAc", "select 1"], capture_output=True, text=True,
                                    env={**env, "PGHOST": host, "PGPORT": "5432"})
            if result.returncode == 0:
                save_env("SUPABASE_DB_POOLER", host)
                print(f"== the database is reachable through {host}; saved as SUPABASE_DB_POOLER")
                return host
    sys.exit("couldn't reach the database directly or through a pooler: paste Accounts/schema.sql "
             "into the SQL editor instead, and remove SUPABASE_DB_URL from .env.local")


def save_env(name, value):
    with open(ENV) as f:
        lines = [line for line in f.read().splitlines() if not line.startswith(f"{name}=")]
    with open(ENV, "w") as f:
        f.write("\n".join(lines + [f"{name}={value}"]) + "\n")


def sql(db_url, *args):
    result = subprocess.run([psql(), "-v", "ON_ERROR_STOP=1", "-q", *args], capture_output=True, text=True,
                            env=connection(db_url))
    if result.returncode != 0:
        sys.exit("psql failed: " + result.stderr.strip()[:600]
                 + "\n(if it can't connect, use the Session pooler connection string from Connect › URI)")
    return result.stdout


def call(url, key, method, path, body=None, token=None, content_type="application/json"):
    data = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else None)
    headers = {"apikey": key, "Content-Type": content_type}
    # Newer publishable keys aren't JWTs, so only a user's token goes in Authorization.
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url + "/" + path, method=method, data=data, headers=headers)
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

    room_folder = f"{user}/{uuid.uuid4()}"
    room_files = {"room.usdz": "model/vnd.usdz+zip", "room.ply": "application/octet-stream",
                  "room.json": "application/json", "room-edits.json": "application/json"}
    for filename, content_type in room_files.items():
        call(url, key, "POST", f"storage/v1/object/room-layouts/{room_folder}/{filename}",
             b"check", token, content_type)
    call(url, key, "POST", "rest/v1/room_layouts",
         {"name": "setup room", "model_path": f"{room_folder}/room.usdz",
          "ply_path": f"{room_folder}/room.ply", "json_path": f"{room_folder}/room.json",
          "edits_path": f"{room_folder}/room-edits.json"}, token)
    rooms = call(url, key, "GET", "rest/v1/room_layouts?select=id,model_path", token=token)
    assert len(rooms) == 1, rooms
    call(url, key, "DELETE", f"rest/v1/room_layouts?id=eq.{rooms[0]['id']}", token=token)
    call(url, key, "DELETE", "storage/v1/object/room-layouts",
         {"prefixes": [f"{room_folder}/{name}" for name in room_files]}, token)
    print("== object and room-layout sign-up, upload, save, list and delete all work")
    if env.get("SUPABASE_DB_URL"):
        sql(env["SUPABASE_DB_URL"], "-c", f"delete from auth.users where email = '{email}'")
        print("   (and the throwaway user is gone)")
    else:
        print(f"   delete the throwaway user {email} under Authentication › Users")


if __name__ == "__main__":
    main()
