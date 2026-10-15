# pocket-id-auth

Declarative OIDC client configuration for [Pocket-ID](https://pocket-id.org).

A NixOS module that syncs OIDC application declarations into Pocket-ID via its REST API idempotently. Services that want OIDC authentication declare their client requirements in Nix, and this module creates or updates them on every deploy.

## Why

Pocket-ID's Web UI is fine for one-off setup, but when you have many services (Sonarr, Radarr, Grafana, Homarr, etc.), each needing an OIDC client, it's tedious and error-prone. This module makes the OIDC client registry part of your NixOS config — declarative, version-controlled, reproducible.

## Usage

### 1. Add the flake input

```nix
# flake.nix
inputs = {
  pocket-id-nixos.url = "github:ogglord/pocket-id-nixos";
  pocket-id-nixos.inputs.nixpkgs.follows = "nixpkgs"; # only used by this repo's tests
};
```

### 2. Import the module and declare clients

```nix
{ inputs, ... }:
{
  imports = [ inputs.pocket-id-nixos.nixosModules.default ];

  services.pocket-id = {
    enable = true;
    settings.APP_URL = "https://auth.example.com";
    credentials = {
      ENCRYPTION_KEY = "/run/secrets/pocket-id/ENCRYPTION_KEY";
      # The API key the sync authenticates with; the module picks it up from here.
      STATIC_API_KEY = "/run/secrets/pocket-id/STATIC_API_KEY";
    };
  };

  services.pocket-id-auth = {
    enable = true;
    clients.grafana = {
      name = "Grafana";
      redirectUris = [ "https://grafana.example.com/login/generic_oauth" ];
      # Optional: declare the secret too, and give Grafana the same file.
      secretFile = "/run/secrets/grafana/OIDC_CLIENT_SECRET";
    };
  };
}
```

`id` defaults to the attribute name. `baseUrl` defaults to Pocket-ID's own
port on `127.0.0.1`, and `staticApiKeyFile` to
`services.pocket-id.credentials.STATIC_API_KEY`, so most setups need nothing
else. Generate the keys with `openssl rand -base64 32`; any secrets manager
(sops-nix, agenix, …) that produces a file works.

### 3. Deploy

`pocket-id-declarative-sync.service` (a oneshot) runs after every Pocket-ID
start and again on every switch that changes the declared config. It creates
missing clients, updates existing ones in place, and applies `appConfig`. A
failed sync fails the unit (`systemctl status pocket-id-declarative-sync`).

#### Client secrets

- **With `secretFile`** the declared secret becomes the client's only valid
  secret: it is installed when it changes and every other secret of that
  client is revoked. Rotating means changing the file.
- **Without it**, Pocket-ID generates a secret when the client is created and
  the sync prints it once to its journal
  (`journalctl -u pocket-id-declarative-sync`). Store it somewhere; it is not
  shown again. Existing clients keep their secrets.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable declarative OIDC client sync |
| `baseUrl` | string | `http://127.0.0.1:<services.pocket-id.settings.PORT or 1411>` | Pocket-ID base URL the sync talks to |
| `staticApiKeyFile` | path or null | `services.pocket-id.credentials.STATIC_API_KEY` | File containing the STATIC_API_KEY |
| `prune` | bool | `false` | Delete clients not declared in the config |
| `clients.*` | submodule | — | OIDC client definitions |
| `appConfig` | attrs of string | `{}` | App config values applied via API (SMTP, email, etc.) |

### Client options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | string | attribute name | OIDC client ID (kebab-case, used as the API identifier) |
| `name` | string | — | Human-readable display name |
| `redirectUris` | list of string | `[]` | OIDC callback/redirect URIs |
| `logoutRedirectUris` | list of string | `[]` | Post-logout redirect URIs |
| `isPublic` | bool | `false` | Client is public (no secret, forces PKCE) |
| `pkceEnabled` | bool | `true` | Require PKCE |
| `requiresReauthentication` | bool | `false` | Re-authenticate on every use |
| `requiresPushedAuthorizationRequests` | bool | `false` | Require PAR |
| `launchURL` | string | `""` | Launch URL shown in Pocket-ID |
| `secretFile` | path or null | `null` | Declared client secret (≥ 16 printable characters); null = generated once |
| `customClaims` | attrs of string | `{}` | Custom OIDC claims for users of this client |

## Custom Claims

You can include custom claims in OIDC tokens for users of a client:

```nix
services.pocket-id-auth.clients.immich = {
  id = "immich";
  name = "Immich";
  redirectUris = [ "https://immich.example.com/oauth/callback" ];
  customClaims = {
    immich_role = "user";
    department  = "media";
  };
};
```

When `customClaims` is set, the module:

1. Creates a user group named `{client-id}-users` (e.g. `immich-users`)
2. Sets the custom claims on that group
3. Restricts the OIDC client to that group (`isGroupRestricted = true`)
4. Users added to the group receive the claims in their OIDC tokens

You can add users to the group through the Pocket-ID web UI under **User Groups**.

## Pruning

When `prune = true`, clients that exist in Pocket-ID but are not declared in
your NixOS config are automatically deleted. Use with care.

## Application Configuration

You can manage Pocket-ID app settings (SMTP, email, etc.) declaratively:

```nix
services.pocket-id-auth.appConfig = {
  smtpHost = "127.0.0.1";
  smtpPort = "587";
  smtpFrom = "homelab@example.com";
  smtpTls = "starttls";
  smtpSkipCertVerify = "false";
  emailVerificationEnabled = "true";
};
```

Settings are applied idempotently on every sync — only updated when values
differ from the current state. Only the keys you specify are enforced;
other keys (e.g. app name, LDAP config) are left as-is.

See the
[AppConfigUpdateDto](https://github.com/pocket-id/pocket-id/blob/main/backend/internal/dto/app_config_dto.go)
for all available keys (SMTP, LDAP, email, UI config, etc.).

## How it works

`sync.py` runs as `pocket-id-declarative-sync.service` (DynamicUser, the API
key passed with `LoadCredential`). It:

1. Fetches the existing OIDC clients and user groups from Pocket-ID's API
2. For each declared client: creates it if missing, updates it if present,
   and installs its declared secret if that changed
3. If the client has `customClaims`: creates a user group, sets the claims,
   and links the group to the client (group-restricted)
4. If `prune` is enabled: deletes any undeclared clients
5. Applies `appConfig`

It talks to Pocket-ID over `baseUrl` with the `STATIC_API_KEY`; nothing else
is needed.

## Development

`nix flake check` runs a NixOS VM test (`test.nix`) against a real Pocket-ID:
clients, custom claims, declared secrets, app config, a config change on
switch, and a re-sync on restart. CI runs it on every push and weekly against
the current `nixos-unstable` and stable branches. `nix fmt` formats.
