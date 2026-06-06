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

  # JSON config with client definitions, written as a separate store path.
  clientsJson = builtins.toJSON (lib.mapAttrsToList (name: c: {
    id = c.id;
    name = c.name;
    callbackURLs = map (u: lib.removeSuffix "/" u) c.redirectUris;
    logoutCallbackURLs = map (u: lib.removeSuffix "/" u) c.logoutRedirectUris;
    isPublic = c.isPublic;
    pkceEnabled = c.pkceEnabled;
    requiresReauthentication = c.requiresReauthentication;
    requiresPushedAuthorizationRequests = c.requiresPushedAuthorizationRequests;
    launchURL = if c.launchURL != "" then c.launchURL else null;
  }) cfg.clients);

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

def request(method, path, data=None):
    url = BASE + path
    headers = {"X-API-Key": open(KEY_FILE).read().strip()}
    if data is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode()
    else:
        body = None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
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

existing = fetch_all("/api/oidc/clients")
existing_by_id = {c["id"]: c for c in existing}

for c in clients:
    id_ = c["id"]
    name = c.get("name", id_)
    print(f"  client: {id_} ({name})")
    if id_ in existing_by_id:
        print("    => updating")
        result = request("PUT", f"/api/oidc/clients/{id_}", c)
        if result is None:
            die(f"Failed to update client {id_}")
    else:
        print("    => creating")
        result = request("POST", "/api/oidc/clients", c)
        if result is None:
            die(f"Failed to create client {id_}")

if PRUNE:
    print("pocket-id-declarative: Pruning undeclared clients...")
    for c in existing:
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
