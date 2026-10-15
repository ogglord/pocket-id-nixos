"""Sync declared OIDC clients and app config into Pocket-ID over its REST API.

Usage: sync.py <config.json>

config.json: {"baseUrl", "clients": [...], "appConfig": {...}, "prune": bool}
The API key (Pocket-ID's STATIC_API_KEY) is read from $CREDENTIALS_DIRECTORY/api-key
(systemd LoadCredential), or from the file named by $POCKET_ID_API_KEY_FILE.
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request

CONFIG = json.load(open(sys.argv[1]))
BASE = CONFIG["baseUrl"].rstrip("/")
KEY_FILE = os.environ.get("POCKET_ID_API_KEY_FILE") or os.path.join(
    os.environ.get("CREDENTIALS_DIRECTORY", ""), "api-key"
)
PRUNE = CONFIG["prune"]
CREDENTIALS = os.environ.get("CREDENTIALS_DIRECTORY", "")
# Declared secrets installed so far: {client id: {"sha256", "secretId"}}.
STATE_FILE = os.path.join(os.environ.get("STATE_DIRECTORY", "/tmp"), "secrets.json")

def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)

def headers():
    return {"X-API-Key": open(KEY_FILE).read().strip()}

def request(method, path, data=None):
    url = BASE + path
    h = headers()
    if data is not None:
        h["Content-Type"] = "application/json"
        body = json.dumps(data).encode()
    else:
        body = None
    req = urllib.request.Request(url, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            body = resp.read()
            return json.loads(body.decode()) if body else {}
    except urllib.error.HTTPError as e:
        print(f"ERROR: {method} {path} returned {e.code}", file=sys.stderr)
        print(e.read().decode(), file=sys.stderr)
        return None

def fetch_all(path):
    page = 1
    total_pages = 1
    result = []
    while page <= total_pages:
        resp = request("GET", f"{path}?pagination[page]={page}&pagination[limit]=100")
        if resp is None:
            die(f"Failed to GET {path}")
        result.extend(resp.get("data", []))
        total_pages = resp.get("pagination", {}).get("totalPages", 1)
        page += 1
    return result

def load_state():
    try:
        return json.load(open(STATE_FILE))
    except (OSError, ValueError):
        return {}

def save_state(state):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE_FILE)

def sync_secret(cid, credential):
    """Make the declared secret the client's only valid secret."""
    value = open(os.path.join(CREDENTIALS, credential)).read().strip()
    digest = hashlib.sha256(value.encode()).hexdigest()
    state = load_state()
    secrets = request("GET", f"/api/oidc/clients/{cid}/secrets")
    if secrets is None:
        die(f"Failed to list secrets of client {cid}")
    ids = {s["id"] for s in secrets}
    known = state.get(cid, {})
    if known.get("sha256") == digest and known.get("secretId") in ids:
        keep = known["secretId"]
    else:
        print("    => installing declared secret")
        created = request("POST", f"/api/oidc/clients/{cid}/secrets", {"secret": value})
        if created is None:
            die(f"Failed to set the declared secret of client {cid}")
        keep = created["id"]
        state[cid] = {"sha256": digest, "secretId": keep}
        save_state(state)
    for sid in ids - {keep}:
        print(f"    => revoking undeclared secret {sid}")
        if request("DELETE", f"/api/oidc/clients/{cid}/secrets/{sid}") is None:
            die(f"Failed to revoke secret {sid} of client {cid}")

# ── Wait for Pocket-ID ──────────────────────────────────────────
for _ in range(30):
    try:
        url = BASE + "/healthz"
        with urllib.request.urlopen(url, timeout=2) as resp:
            if resp.status == 204:
                break
    except Exception:
        pass
    time.sleep(1)

clients = CONFIG["clients"]
print("pocket-id-declarative: Syncing OIDC clients...")

existing_clients = fetch_all("/api/oidc/clients")
existing_by_id = {c["id"]: c for c in existing_clients}
existing_groups = fetch_all("/api/user-groups")
groups_by_name = {g["name"]: g for g in existing_groups}

# ── Sync OIDC clients ───────────────────────────────────────────
for c in clients:
    cid = c["id"]
    name = c.get("name", cid)
    print(f"  client: {cid} ({name})")

    # Build payload (strip internal fields; force isGroupRestricted when customClaims exist)
    payload = {k: v for k, v in c.items() if k in (
        "id", "name", "callbackURLs", "logoutCallbackURLs",
        "isPublic", "pkceEnabled", "requiresReauthentication",
        "requiresPushedAuthorizationRequests", "launchURL"
    )}
    if c.get("userGroupName"):
        payload["isGroupRestricted"] = True

    if cid in existing_by_id:
        print("    => updating")
        result = request("PUT", f"/api/oidc/clients/{cid}", payload)
        if result is None:
            die(f"Failed to update client {cid}")
    else:
        print("    => creating")
        result = request("POST", "/api/oidc/clients", payload)
        if result is None:
            die(f"Failed to create client {cid}")
        if not c.get("secretCredential") and not c.get("isPublic"):
            # No declared secret: generate one and print it once.
            # Pocket-ID 2.x generates one on creation (AUTO_CREATE_OIDC_CLIENT_SECRET).
            sec = result.get("createdSecret")
            if sec is None:
                print("    => generating secret")
                sec = request("POST", f"/api/oidc/clients/{cid}/secrets", {})
            if sec is not None and "secret" in sec:
                print("\n" + "=" * 60)
                print(f"  NEW CLIENT: {cid}")
                print(f"  Client ID:     {cid}")
                print(f"  Client Secret: {sec['secret']}")
                print(f"  Issuer URL:    {BASE}/.well-known/openid-configuration")
                print("=" * 60 + "\n")

    if c.get("secretCredential"):
        sync_secret(cid, c["secretCredential"])

    # ── User group + custom claims ──────────────────────────────
    group_name = c.get("userGroupName")
    custom_claims = c.get("customClaims", {})
    if group_name and custom_claims:
        # Create / get group
        if group_name in groups_by_name:
            gid = groups_by_name[group_name]["id"]
            print(f"    group: {group_name} (exists)")
        else:
            print(f"    group: {group_name} (creating)")
            g = request("POST", "/api/user-groups", {"name": group_name, "friendlyName": group_name})
            if g is None:
                die(f"Failed to create group {group_name}")
            gid = g["id"]
            existing_groups.append(g)

        # Set custom claims on the group
        claims_payload = [{"key": k, "value": v} for k, v in custom_claims.items()]
        print(f"    claims: {[k for k in custom_claims]}")
        r = request("PUT", f"/api/custom-claims/user-group/{gid}", claims_payload)
        if r is None:
            die(f"Failed to set custom claims for group {group_name}")

        # Link group → client
        print("    linking group to client")
        r = request("PUT", f"/api/oidc/clients/{cid}/allowed-user-groups", {"userGroupIds": [gid]})
        if r is None:
            die(f"Failed to link group {group_name} to client {cid}")

        # Link client → group (bidirectional)
        r = request("PUT", f"/api/user-groups/{gid}/allowed-oidc-clients",
                     {"oidcClientIds": [cid]})
        if r is None:
            die(f"Failed to link client {cid} to group {group_name}")

# ── Prune undeclared clients ────────────────────────────────────
if PRUNE:
    declared_ids = {c["id"] for c in clients}
    print("pocket-id-declarative: Pruning undeclared clients...")
    for c in existing_clients:
        if c["id"] not in declared_ids:
            print(f"  pruning: {c['id']}")
            result = request("DELETE", f"/api/oidc/clients/{c['id']}")
            if result is None:
                print(f"    warning: failed to delete {c['id']}", file=sys.stderr)

print("pocket-id-declarative: Sync complete")

# ── App config (SMTP, etc.) ──────────────────────────────────────
desired = CONFIG["appConfig"]
if desired:
    print("pocket-id-declarative: Syncing app config...")
    req = request("GET", "/api/application-configuration/all")
    if req is not None:
        current = {c["key"]: c["value"] for c in req}
        merged = {**current, **desired}
        dirty = any(desired.get(k) != current.get(k) for k in desired)
        if dirty:
            print("  updating settings:", list(desired.keys()))
            r = request("PUT", "/api/application-configuration", merged)
            if r is not None:
                print("  app config updated")
        else:
            print("  app config up to date")
