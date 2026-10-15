{
  config,
  pkgs,
  lib,
  ...
}:

# Declarative Pocket-ID OIDC clients and app config.
#
# Clients are declared as
#   services.pocket-id-auth.clients.<name> = { ... }
# and synced into Pocket-ID by `pocket-id-declarative-sync.service`
# (sync.py, Pocket-ID's REST API authenticated with its STATIC_API_KEY).
# The sync runs whenever Pocket-ID starts and whenever the declared config
# changes; it creates or updates each client idempotently.

let
  cfg = config.services.pocket-id-auth;
  pocketId = config.services.pocket-id;

  # 2.14.0: multiple client secrets (/api/oidc/clients/<id>/secrets), which
  # the sync uses; STATIC_API_KEY has existed since 2.2.0.
  minVersion = "2.14.0";

  # Clients as Pocket-ID's API wants them; custom claims ride on an
  # auto-created user group the client is restricted to.
  clientDefs = lib.mapAttrsToList (
    _: c:
    let
      hasClaims = c.customClaims != { };
    in
    {
      inherit (c)
        id
        name
        isPublic
        pkceEnabled
        requiresReauthentication
        requiresPushedAuthorizationRequests
        ;
      callbackURLs = map (lib.removeSuffix "/") c.redirectUris;
      logoutCallbackURLs = map (lib.removeSuffix "/") c.logoutRedirectUris;
      launchURL = if c.launchURL != "" then c.launchURL else null;
      customClaims = if hasClaims then c.customClaims else { };
      userGroupName = if hasClaims then "${c.id}-users" else null;
      secretCredential = if c.secretFile != null then "client-${c.id}" else null;
    }
  ) cfg.clients;

  syncConfig = pkgs.writeText "pocket-id-declarative.json" (
    builtins.toJSON {
      inherit (cfg) baseUrl appConfig prune;
      clients = clientDefs;
    }
  );
in
{
  options.services.pocket-id-auth = {
    enable = lib.mkEnableOption "declarative Pocket-ID OIDC client sync";

    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:${toString (pocketId.settings.PORT or 1411)}";
      defaultText = lib.literalExpression ''"http://127.0.0.1:''${toString (config.services.pocket-id.settings.PORT or 1411)}"'';
      description = "Pocket-ID base URL the sync talks to (its local listener).";
    };

    staticApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = pocketId.credentials.STATIC_API_KEY or null;
      defaultText = lib.literalExpression "config.services.pocket-id.credentials.STATIC_API_KEY or null";
      description = ''
        File containing Pocket-ID's STATIC_API_KEY. Defaults to the file given
        to Pocket-ID itself via `services.pocket-id.credentials.STATIC_API_KEY`,
        so the key is declared once.
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
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              id = lib.mkOption {
                type = lib.types.str;
                default = name;
                defaultText = lib.literalExpression "<name>";
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
                example = [ "https://sonarr.example.com/oauth/callback" ];
                description = "OIDC callback/redirect URIs. Supports wildcards (e.g. https://*.example.com/*).";
              };

              logoutRedirectUris = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "https://sonarr.example.com/logout" ];
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
                example = "https://sonarr.example.com";
                description = "Launch URL for the application (shown in Pocket-ID).";
              };

              secretFile = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                example = "/run/secrets/grafana/OIDC_CLIENT_SECRET";
                description = ''
                  File holding the client secret (at least 16 printable
                  characters). The sync makes it the client's only valid
                  secret, so the service using the client can read the same
                  file. When null, a secret is generated once at creation and
                  printed to the sync unit's journal.
                '';
              };

              customClaims = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
                example = {
                  immich_role = "user";
                };
                description = ''
                  Custom OIDC claims to include in tokens for users of this client.
                  A user group (named <id>-users) is auto-created, gets these
                  claims, and the client is restricted to it.
                '';
              };
            };
          }
        )
      );
    };

    appConfig = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        smtpHost = "127.0.0.1";
        smtpPort = "587";
        smtpTls = "starttls";
        smtpFrom = "homelab@example.com";
      };
      description = ''
        Application configuration values to apply idempotently via the
        Pocket-ID API (PUT /api/application-configuration).
        Only specified keys are enforced; existing values for other keys
        are preserved.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pocketId.enable;
        message = "services.pocket-id-auth needs services.pocket-id.enable = true.";
      }
      {
        assertion = lib.versionAtLeast (lib.getVersion pocketId.package) minVersion;
        message = "services.pocket-id-auth needs Pocket-ID >= ${minVersion}; services.pocket-id.package is ${lib.getVersion pocketId.package}.";
      }
      {
        assertion = lib.all (c: !(c.isPublic && c.secretFile != null)) (lib.attrValues cfg.clients);
        message = "services.pocket-id-auth: a public client cannot have a secretFile.";
      }
      {
        assertion = cfg.staticApiKeyFile != null;
        message = ''
          services.pocket-id-auth needs Pocket-ID's STATIC_API_KEY: set
          services.pocket-id.credentials.STATIC_API_KEY (preferred) or
          services.pocket-id-auth.staticApiKeyFile.
        '';
      }
    ];

    systemd.services.pocket-id-declarative-sync = {
      description = "Sync declared OIDC clients into Pocket-ID";
      # Runs after every Pocket-ID start (wanted by it), and on every switch
      # that adds or changes it (wanted by multi-user.target). It never starts
      # Pocket-ID itself: while Pocket-ID is not running it is skipped, not
      # failed, and runs when Pocket-ID next starts.
      wantedBy = [
        "multi-user.target"
        "pocket-id.service"
      ];
      partOf = [ "pocket-id.service" ];
      after = [ "pocket-id.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecCondition = "${pkgs.systemd}/bin/systemctl is-active --quiet pocket-id.service";
        ExecStart = "${lib.getExe pkgs.python3} ${./sync.py} ${syncConfig}";
        LoadCredential = [
          "api-key:${cfg.staticApiKeyFile}"
        ]
        ++ lib.mapAttrsToList (_: c: "client-${c.id}:${c.secretFile}") (
          lib.filterAttrs (_: c: c.secretFile != null) cfg.clients
        );
        # Which declared secret is installed under which secret id.
        StateDirectory = "pocket-id-declarative";
        DynamicUser = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };
  };
}
