{ config, pkgs, lib, ... }:

# Declarative Pocket-ID OIDC client configuration.
#
# Services declare their OIDC client requirements via
#   services.pocket-id-auth.clients.<name> = { ... }
#
# A sync script runs on every deploy via postStart and creates or updates
# each client idempotently using Pocket-ID's REST API (STATIC_API_KEY).
#
# Prerequisites:
#   - A running Pocket-ID instance (services.pocket-id.enable or equivalent)
#   - STATIC_API_KEY set in Pocket-ID and accessible via staticApiKeyFile

let
  cfg = config.services.pocket-id-auth;

  # Normalise a list of URLs for the API payload (strip trailing slashes, flatten).
  normaliseUrls = urls: map (u: lib.removeSuffix "/" u) urls;

  # Build an idempotent sync script that:
  #   1. Fetches existing OIDC clients from Pocket-ID
  #   2. Creates any that don't exist
  #   3. Updates any that do

  syncScript = pkgs.writeShellScriptBin "pocket-id-declarative-sync" ''
    set -euo pipefail
    export PATH="${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH"

    # ── Config ────────────────────────────────────────────────────────────
      BASE="${cfg.baseUrl}"
      KEY_FILE="${cfg.staticApiKeyFile}"

      if [ ! -f "$KEY_FILE" ]; then
        echo "pocket-id-declarative: STATIC_API_KEY file not found at $KEY_FILE" >&2
        exit 1
      fi
      KEY=$(cat "$KEY_FILE")

      # Wait for Pocket-ID to be ready
      for i in $(seq 1 30); do
        if curl -sf -o /dev/null "$BASE/healthz" 2>/dev/null; then break; fi
        sleep 1
      done

      die() { echo "ERROR: $*" >&2; exit 1; }

      api() {
        local method=$1 path=$2 data=${3:-}
        shift 2
        if [ -n "$data" ]; then
          curl -sf -X "$method" "$BASE$path" \
            -H "X-API-Key: $KEY" \
            -H "Content-Type: application/json" \
            -d "$data"
        else
          curl -sf -X "$method" "$BASE$path" \
            -H "X-API-Key: $KEY"
        fi
      }

      # ── Helper: fetch all pages of a paginated endpoint ──────────────────
      fetch_all() {
        local path=$1
        local page=1
        local total_pages=1
        local result="[]"
        while [ "$page" -le "$total_pages" ]; do
          local resp
          resp=$(api GET "$path?pagination[page]=$page&pagination[limit]=100") || die "Failed to GET $path"
          local data
          data=$(echo "$resp" | jq '.data // []')
          total_pages=$(echo "$resp" | jq '.pagination.totalPages // 1')
          result=$(echo "$result" "$data" | jq -s 'add')
          page=$((page + 1))
        done
        echo "$result"
      }

      # ── Sync OIDC clients ─────────────────────────────────────────────────
      echo "pocket-id-declarative: Syncing OIDC clients..."

      EXISTING=$(fetch_all "/api/oidc/clients" 2>/tmp/pocket-oidc-error.txt || {
        echo "Failed to fetch existing clients (status code unknown). Response body:" >&2
        cat /tmp/pocket-oidc-error.txt >&2 2>/dev/null || true
        die "Failed to fetch existing clients"
      })

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (clientName: client: let
        c = client;
        # Build the API payload
        payload = builtins.toJSON {
          id = c.id;
          name = c.name;
          callbackURLs = normaliseUrls c.redirectUris;
          logoutCallbackURLs = normaliseUrls c.logoutRedirectUris;
          isPublic = c.isPublic;
          pkceEnabled = c.pkceEnabled;
          requiresReauthentication = c.requiresReauthentication;
          requiresPushedAuthorizationRequests = c.requiresPushedAuthorizationRequests;
          launchURL = if c.launchURL != "" then c.launchURL else null;
          isGroupRestricted = false;
        };
        escapedPayload = lib.escapeShellArg payload;
      in ''
        echo "  client: ${lib.escapeShellArg c.id} (${lib.escapeShellArg c.name})"

        ID=${lib.escapeShellArg c.id}
        EXISTS=$(echo "$EXISTING" | jq -r '.[] | select(.id == $id) | .id // empty' --arg id "$ID")

        if [ -z "$EXISTS" ]; then
          echo "    → creating"
          api POST "/api/oidc/clients" ${escapedPayload} >/dev/null || die "Failed to create client ${c.id}"
        else
          echo "    → updating"
          api PUT "/api/oidc/clients/$EXISTS" ${escapedPayload} >/dev/null || die "Failed to update client ${c.id}"
        fi
      '') cfg.clients)}

      # ── Delete clients not in config (cleanup) ────────────────────────────
      if ${lib.boolToString cfg.prune}; then
        echo "pocket-id-declarative: Pruning undeclared clients..."
        DECLARED_IDS=" ${lib.concatStringsSep " " (lib.attrValues (lib.mapAttrs (n: c: c.id) cfg.clients))} "
        echo "$EXISTING" | jq -r '.[].id' | while read -r id; do
          case "$DECLARED_IDS" in
            *" $id "*) ;;
            *)
              echo "  pruning: $id"
              api DELETE "/api/oidc/clients/$id" >/dev/null || echo "    warning: failed to delete $id" >&2
              ;;
          esac
        done
      fi

      echo "pocket-id-declarative: Sync complete"
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
    # Hook the sync script into Pocket-ID's postStart so it runs after every
    # service restart (which happens on every nh os switch).
    systemd.services.pocket-id = lib.mkIf config.services.pocket-id.enable {
      postStart = lib.mkAfter ''
        ${lib.getExe syncScript} || echo "pocket-id-declarative: sync failed (non-fatal)" >&2
      '';
    };

    # Also run on activation if pocket-id is already running.
    system.activationScripts.pocket-id-declarative = lib.mkIf config.services.pocket-id.enable ''
      if systemctl is-active --quiet pocket-id.service 2>/dev/null; then
        ${lib.getExe syncScript}
      fi
    '';
  };
}
