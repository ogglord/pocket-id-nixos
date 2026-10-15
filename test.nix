# End-to-end: a real Pocket-ID, two declared clients (one with custom claims),
# an app setting, then a config change applied by switching specialisations.
{ self }:
{
  name = "pocket-id-auth";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];

      services.pocket-id = {
        enable = true;
        settings = {
          APP_URL = "http://localhost:1411";
          TRUST_PROXY = false;
        };
        # Test-only secrets in the store.
        credentials = {
          ENCRYPTION_KEY = pkgs.writeText "encryption-key" "0123456789abcdef0123456789abcdef";
          STATIC_API_KEY = pkgs.writeText "static-api-key" "test-api-key-0123456789abcdef";
        };
      };

      services.pocket-id-auth = {
        enable = true;
        clients.grafana = {
          name = "Grafana";
          secretFile = pkgs.writeText "grafana-secret" "grafana-declared-secret-1";
          redirectUris = [ "https://grafana.example.com/login/generic_oauth" ];
        };
        clients.photos = {
          id = "immich";
          name = "Immich";
          redirectUris = [ "https://immich.example.com/auth/login" ];
          customClaims.immich_role = "user";
        };
        appConfig.smtpHost = "mail.example.com";
      };

      specialisation.renamed.configuration = {
        services.pocket-id-auth = {
          clients.grafana.name = pkgs.lib.mkForce "Grafana (renamed)";
          clients.grafana.secretFile = pkgs.lib.mkForce (
            pkgs.writeText "grafana-secret-2" "grafana-declared-secret-2"
          );
          prune = true;
        };
      };

      environment.systemPackages = [
        pkgs.curl
        pkgs.jq
      ];
    };

  testScript =
    { nodes, ... }:
    let
      renamed = "${nodes.machine.system.build.toplevel}/specialisation/renamed";
    in
    ''
      import json

      def api(path):
          return json.loads(machine.succeed(
              f"curl -sf -H 'X-API-Key: test-api-key-0123456789abcdef' http://127.0.0.1:1411{path}"
          ))

      machine.wait_for_unit("pocket-id.service")
      machine.wait_for_unit("pocket-id-declarative-sync.service")

      with subtest("declared clients exist"):
          clients = {c["id"]: c for c in api("/api/oidc/clients")["data"]}
          assert set(clients) == {"grafana", "immich"}, clients
          assert clients["grafana"]["name"] == "Grafana"

      with subtest("custom claims ride on a group the client is restricted to"):
          groups = {g["name"]: g for g in api("/api/user-groups")["data"]}
          assert "immich-users" in groups, groups

      def token_ok(secret):
          # client_credentials needs a grant the client may not have; a wrong
          # secret is rejected as invalid_client before that, a right one is not.
          out = machine.succeed(
              "curl -s -u grafana:" + secret + " -d grant_type=client_credentials http://127.0.0.1:1411/api/oidc/token"
          )
          return "invalid_client" not in out and "nvalid client" not in out, out

      with subtest("the declared secret is the client's only secret"):
          secrets = api("/api/oidc/clients/grafana/secrets")
          assert len(secrets) == 1 and secrets[0]["prefix"] == "graf", secrets
          ok, out = token_ok("grafana-declared-secret-1")
          assert ok, out
          ok, out = token_ok("wrong-secret-0123456789")
          assert not ok, out
          # A generated secret for the client without secretFile.
          assert len(api("/api/oidc/clients/immich/secrets")) == 1

      with subtest("app config applied"):
          cfg = {c["key"]: c["value"] for c in api("/api/application-configuration/all")}
          assert cfg["smtpHost"] == "mail.example.com", cfg["smtpHost"]

      with subtest("a config change is synced on switch"):
          machine.succeed("${renamed}/bin/switch-to-configuration test")
          machine.wait_for_unit("pocket-id-declarative-sync.service")
          clients = {c["id"]: c for c in api("/api/oidc/clients")["data"]}
          assert clients["grafana"]["name"] == "Grafana (renamed)", clients["grafana"]
          secrets = api("/api/oidc/clients/grafana/secrets")
          assert len(secrets) == 1, secrets
          ok, out = token_ok("grafana-declared-secret-2")
          assert ok, out
          ok, out = token_ok("grafana-declared-secret-1")
          assert not ok, out

      with subtest("restarting Pocket-ID re-runs the sync"):
          machine.succeed("systemctl restart pocket-id.service")
          machine.wait_for_unit("pocket-id-declarative-sync.service")
          machine.succeed("journalctl -u pocket-id-declarative-sync -b | grep -c 'Sync complete' | grep -qv '^1$'")
    '';
}
