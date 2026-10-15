# pocket-id-nixos

Declare [Pocket-ID](https://pocket-id.org)'s OIDC clients, their secrets and
its app settings in NixOS, instead of clicking them together in the web UI.

## Why this exists

NixOS's `services.pocket-id` runs Pocket-ID, but everything you configure
*inside* it (OIDC clients, redirect URIs, client secrets, user groups and
claims, SMTP) lives only in its database. That breaks the NixOS promise:

- a rebuild on a fresh machine gives you a Pocket-ID with no clients;
- the service and its OIDC client are declared in two places, one of them a UI;
- client secrets are copied out of a web page into your secrets manager by hand.

This module closes the gap. You declare clients next to the services that use
them; on every deploy a small sync applies them through Pocket-ID's REST API,
idempotently. A client secret can come from the same sops/agenix file the
service reads, so nothing is copied by hand.

## Usage

Requires **NixOS 26.05** or newer (Pocket-ID 2.14.0+, checked at build time).

```nix
# flake.nix
inputs.pocket-id-nixos.url = "github:ogglord/pocket-id-nixos";
inputs.pocket-id-nixos.inputs.nixpkgs.follows = "nixpkgs";
```

```nix
{ inputs, ... }:
{
  imports = [ inputs.pocket-id-nixos.nixosModules.default ];

  services.pocket-id = {
    enable = true;
    settings.APP_URL = "https://auth.example.com";
    credentials = {
      ENCRYPTION_KEY = "/run/secrets/pocket-id/ENCRYPTION_KEY";
      STATIC_API_KEY = "/run/secrets/pocket-id/STATIC_API_KEY"; # the sync uses it too
    };
  };

  services.pocket-id-auth = {
    enable = true;

    clients.grafana = {
      name = "Grafana";
      redirectUris = [ "https://grafana.example.com/login/generic_oauth" ];
      secretFile = "/run/secrets/grafana/OIDC_CLIENT_SECRET"; # optional
    };

    clients.immich = {
      name = "Immich";
      redirectUris = [ "https://immich.example.com/auth/login" ];
      customClaims.immich_role = "user"; # → group immich-users, client restricted to it
    };

    appConfig = {
      smtpHost = "127.0.0.1";
      smtpPort = "25";
      smtpFrom = "auth@example.com";
    };
  };
}
```

Generate the keys with `openssl rand -base64 32`.

## Behaviour

- **When it runs:** `pocket-id-declarative-sync.service` (oneshot) runs after
  every Pocket-ID start and on every switch that adds or changes it. It never
  starts Pocket-ID; while Pocket-ID is stopped it is skipped. A failed sync
  fails the unit.
- **Clients** are created if missing and updated in place otherwise. With
  `prune = true`, undeclared clients are deleted.
- **Secrets:** with `secretFile`, that secret becomes the client's only valid
  one (installed when it changes, others revoked). Without it, Pocket-ID
  generates one at creation and the sync prints it once:
  `journalctl -u pocket-id-declarative-sync`.
- **Custom claims** go on an auto-created `<id>-users` group that the client is
  restricted to; add users to it in the web UI.
- **`appConfig`** sets only the keys you list
  ([available keys](https://github.com/pocket-id/pocket-id/blob/main/backend/internal/dto/app_config_dto.go));
  everything else is left alone.

## Options

All under `services.pocket-id-auth`.

| Option | Default | |
|---|---|---|
| `enable` | `false` | |
| `clients.<name>.id` | `<name>` | OIDC client id |
| `clients.<name>.name` | | display name |
| `clients.<name>.redirectUris` / `logoutRedirectUris` | `[]` | wildcards allowed |
| `clients.<name>.secretFile` | `null` | declared secret, ≥ 16 printable chars |
| `clients.<name>.isPublic` | `false` | no secret, forces PKCE |
| `clients.<name>.pkceEnabled` | `true` | |
| `clients.<name>.requiresReauthentication` | `false` | |
| `clients.<name>.requiresPushedAuthorizationRequests` | `false` | |
| `clients.<name>.launchURL` | `""` | |
| `clients.<name>.customClaims` | `{}` | |
| `appConfig` | `{}` | |
| `prune` | `false` | delete undeclared clients |
| `baseUrl` | `http://127.0.0.1:<Pocket-ID port>` | |
| `staticApiKeyFile` | `services.pocket-id.credentials.STATIC_API_KEY` | |

## Development

`nix flake check` runs a NixOS VM test against a real Pocket-ID (`test.nix`).
CI runs it on every push and weekly against `nixos-unstable` and the current
stable branch. `nix fmt` formats.
