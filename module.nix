  syncScript = pkgs.writeTextFile {
    name = "pocket-id-declarative-sync";
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      # Ensure runtime tools are available
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
        local method=$1 path=$2 data=$3
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
          local total_pages
          total_pages=$(echo "$resp" | jq '.pagination.totalPages // 1')
          result=$(echo "$result" "$data" | jq -s 'add')
          page=$((page + 1))
        done
        echo "$result"
      }

      # ── Sync OIDC clients ─────────────────────────────────────────────────
      echo "pocket-id-declarative: Syncing OIDC clients..."

      EXISTING=$(fetch_all "/api/oidc/clients") || die "Failed to fetch existing clients"

      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (clientName: client: let
        c = client;
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
      in ''
        echo "  client: ${lib.escapeShellArg c.id} (${lib.escapeShellArg c.name})"

        ID=${lib.escapeShellArg c.id}
        EXISTS=$(echo "$EXISTING" | jq -r '.[] | select(.id == $id) | .id // empty' --arg id "$ID")

        if [ -z "$EXISTS" ]; then
          echo "    → creating"
          api POST "/api/oidc/clients" '${lib.escapeShellArg payload}' >/dev/null || die "Failed to create client ${c.id}"
        else
          echo "    → updating"
          api PUT "/api/oidc/clients/$EXISTS" '${lib.escapeShellArg payload}' >/dev/null || die "Failed to update client ${c.id}"
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
  };
