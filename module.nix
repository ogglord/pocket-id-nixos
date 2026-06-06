{ config, pkgs, lib, ... }:

# Declarative Pocket-ID OIDC client configuration.
#
# Services declare their OIDC client requirements via
#   services.pocket-id-auth.clients.<name> = { ... }
#
# A Python sync script runs on every deploy via postStart and creates or updates
# each client idempotently using Pocket-ID's REST API (STATIC_API_KEY).

let
  cfg = config.services.pocket-id-auth;

  # JSON config: clients + their custom claims / user groups.
  clientDefs = lib.mapAttrsToList (name: c: let
    hasClaims = c.customClaims != {};
    groupName = "${c.id}-users";
  in {
    id = c.id;
    name = c.name;
    callbackURLs = map (u: lib.removeSuffix "/" u) c.redirectUris;
    logoutCallbackURLs = map (u: lib.removeSuffix "/" u) c.logoutRedirectUris;
    isPublic = c.isPublic;
    pkceEnabled = c.pkceEnabled;
    requiresReauthentication = c.requiresReauthentication;
    requiresPushedAuthorizationRequests = c.requiresPushedAuthorizationRequests;
    launchURL = if c.launchURL != "" then c.launchURL else null;
    # Custom claims → auto-create a user group for this client.
    customClaims = if hasClaims then c.customClaims else {};
    userGroupName = if hasClaims then groupName else null;
  }) cfg.clients;

  clientsJson = builtins.toJSON clientDefs;

  clientsFile = pkgs.writeText "pocket-id-clients.json" clientsJson;

  # Python sync script, also in its own store path (no indented-string quoting issues).
  syncPy = pkgs.writeText "pocket-id-declarative-sync.py" ''
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = "${cfg.baseUrl}"
KEY_FILE = "${cfg.staticApiKeyFile}"
CLIENTS_FILE = "${clientsFile}"
PRUNE = ${if cfg.prune then "True" else "False"}
PRUNE_LIST = ${builtins.toJSON (lib.attrNames cfg.clients)}

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

clients = json.load(open(CLIENTS_FILE))
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

    # Build payload (strip internal fields)
    payload = {k: v for k, v in c.items() if k in (
        "id", "name", "callbackURLs", "logoutCallbackURLs",
        "isPublic", "pkceEnabled", "requiresReauthentication",
        "requiresPushedAuthorizationRequests", "launchURL"
    )}

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
            g = request("POST", "/api/user-groups", {"name": group_name})
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
        r = request("PUT", f"/api/oidc/clients/{cid}/allowed-user-groups", [gid])
        if r is None:
            die(f"Failed to link group {group_name} to client {cid}")

        # Link client → group (bidirectional)
        r = request("PUT", f"/api/user-groups/{gid}/allowed-oidc-clients",
                     {"oidcClientIds": [cid]})
        if r is None:
            die(f"Failed to link client {cid} to group {group_name}")

# ── Prune undeclared clients ────────────────────────────────────
if PRUNE:
    print("pocket-id-declarative: Pruning undeclared clients...")
    for c in existing_clients:
        if c["id"] not in PRUNE_LIST:
            print(f"  pruning: {c['id']}")
            result = request("DELETE", f"/api/oidc/clients/{c['id']}")
            if result is None:
                print(f"    warning: failed to delete {c['id']}", file=sys.stderr)

print("pocket-id-declarative: Sync complete")
  '';

  # Shell wrapper that launches the Python script.
  syncScript = pkgs.writeShellScriptBin "pocket-id-declarative-sync" ''
    exec ${pkgs.python3}/bin/python3 ${syncPy}
  '';
in
{
  options.services.pocket-id-auth = {
    enable = lib.mkEnableOption "declarative Pocket-ID OIDC client sync";

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:1411";
      description = "Pocket-ID internal base URL for API calls.";
    };

    staticApiKeyFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to a file containing the STATIC_API_KEY.
        Typically a sops-decrypted secret path like /run/secrets/pocket-id/STATIC_API_KEY.
      '';
    };

    prune = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Delete Pocket-ID clients that are not declared in the config.";
    };

    clients = lib.mkOption {
      description = "OIDC clients to create/update in Pocket-ID.";
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          id = lib.mkOption {
            type = lib.types.str;
            example = "sonarr";
            description = "OIDC client ID. Short, kebab-case identifier. Also used as the unique key for API operations.";
          };

          name = lib.mkOption {
            type = lib.types.str;
            example = "Sonarr";
            description = "Human-readable display name shown in Pocket-ID and on the consent screen.";
          };

          redirectUris = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "https://sonarr.cignl.cc/oauth/callback" ];
            description = "OIDC callback/redirect URIs. Supports wildcards (e.g. https://*.cignl.cc/*).";
          };

          logoutRedirectUris = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "https://sonarr.cignl.cc/logout" ];
            description = "Post-logout redirect URIs.";
          };

          isPublic = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the client is public (no client secret). Forces PKCE to be enabled.";
          };

          pkceEnabled = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Require PKCE (Proof Key for Code Exchange) for this client.";
          };

          requiresReauthentication = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Require the user to re-authenticate each time they use this client.";
          };

          requiresPushedAuthorizationRequests = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Require pushed authorization requests (PAR).";
          };

          launchURL = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = "https://sonarr.cignl.cc";
            description = "Launch URL for the application (shown in Pocket-ID).";
          };

          customClaims = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = { "immich_role" = "user"; };
            description = ''
              Custom OIDC claims to include in tokens for users of this client.
              A user group (named <id>-users) is auto-created and linked to the client.
            '';
          };
        };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.pocket-id = lib.mkIf config.services.pocket-id.enable {
      postStart = lib.mkAfter ''
        ${lib.getExe syncScript} || echo "pocket-id-declarative: sync failed (non-fatal)" >&2
      '';
    };

    system.activationScripts.pocket-id-declarative = lib.mkIf config.services.pocket-id.enable ''
      if systemctl is-active --quiet pocket-id.service 2>/dev/null; then
        ${lib.getExe syncScript}
      fi
    '';
  };
}
