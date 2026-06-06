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
  pocket-id-auth.url = "github:ogglord/pocket-id-auth";
};
```

### 2. Import the module

```nix
# configuration.nix
imports = [
  inputs.pocket-id-auth.nixosModules.default
];
```

### 3. Configure the API connection

```nix
services.pocket-id-auth = {
  enable = true;
  baseUrl = "http://127.0.0.1:1411";                          # Pocket-ID internal URL
  staticApiKeyFile = "/run/secrets/pocket-id/STATIC_API_KEY";  # file containing the API key
};
```

The `STATIC_API_KEY` environment variable must be set in Pocket-ID's environment
(see [Pocket-ID docs](https://pocket-id.org/docs/guides/oidc-client-authentication)).
The sync script will read the key from the file path you specify.

### 4. Declare your OIDC clients

```nix
services.pocket-id-auth.clients.sonarr = {
  id = "sonarr";
  name = "Sonarr";
  redirectUris = [ "https://sonarr.example.com/oauth/callback" ];
  # Optional:
  pkceEnabled = true;
  launchURL = "https://sonarr.example.com";
};

services.pocket-id-auth.clients.radarr = {
  id = "radarr";
  name = "Radarr";
  redirectUris = [ "https://radarr.example.com/oauth/callback" ];
  logoutRedirectUris = [ "https://radarr.example.com/logout" ];
};
```

### 5. Deploy

The sync script runs automatically on every `nixos-rebuild switch` via `postStart`
on the Pocket-ID service. When you add a **new** client, the sync script generates
a client secret and prints it prominently in the deploy output:

```
pocket-id-declarative: Syncing OIDC clients...
  client: sonarr (Sonarr)
    => creating
    => generating secret

============================================================
  NEW CLIENT: sonarr
  Client ID:     sonarr
  Client Secret: yE86uAXABJOIFZZY3OTl7rtoMUezPjvy
  Issuer URL:    http://127.0.0.1:1411/.well-known/openid-configuration
============================================================
```

Capture this secret and store it in your secrets management (e.g. sops-nix, agenix,
or a password manager). The secret is only shown once at creation time. If you need
to rotate a secret later, call:

```bash
curl -X POST http://127.0.0.1:1411/api/oidc/clients/<client-id>/secret \
  -H "X-API-Key: $(cat /run/secrets/pocket-id/STATIC_API_KEY)"
```

Existing clients are updated in-place without regenerating their secrets.

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable declarative OIDC client sync |
| `baseUrl` | string | `"http://127.0.0.1:1411"` | Pocket-ID internal base URL |
| `staticApiKeyFile` | path | — | File containing the STATIC_API_KEY |
| `prune` | bool | `false` | Delete clients not declared in the config |
| `clients.*` | submodule | — | OIDC client definitions |
| `appConfig` | attrs of string | `{}` | App config values applied via API (SMTP, email, etc.) |

### Client options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `id` | string | — | OIDC client ID (kebab-case, used as the API identifier) |
| `name` | string | — | Human-readable display name |
| `redirectUris` | list of string | `[]` | OIDC callback/redirect URIs |
| `logoutRedirectUris` | list of string | `[]` | Post-logout redirect URIs |
| `isPublic` | bool | `false` | Client is public (no secret, forces PKCE) |
| `pkceEnabled` | bool | `true` | Require PKCE |
| `requiresReauthentication` | bool | `false` | Re-authenticate on every use |
| `requiresPushedAuthorizationRequests` | bool | `false` | Require PAR |
| `launchURL` | string | `""` | Launch URL shown in Pocket-ID |
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

On every deploy (and Pocket-ID restart), a Python script runs that:

1. Fetches the list of existing OIDC clients from Pocket-ID's API
2. For each declared client: creates it if missing, updates it if present
3. If the client has `customClaims`: creates a user group, sets the claims,
   and links the group to the client (group-restricted)
4. If `prune` is enabled: deletes any undeclared clients
5. For newly created clients: generates a client secret and prints it

The script communicates with Pocket-ID via the `STATIC_API_KEY` on `127.0.0.1`.
No external dependencies or services required.
