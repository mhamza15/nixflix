{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  inherit (import ../lib/mkVirtualHosts.nix { inherit lib config; }) mkVirtualHost;
  secrets = import ../lib/secrets { inherit lib; };
  mkSecureCurl = import ../lib/mk-secure-curl.nix { inherit lib pkgs; };

  cfg = config.nixflix.profilarr;
  hostname = "${cfg.subdomain}.${config.nixflix.reverseProxy.domain}";
  containerService = config.virtualisation.oci-containers.containers.profilarr.serviceName;
  apiUrl = "http://127.0.0.1:${toString cfg.port}/api/v1";

  databaseType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Display name for the Profilarr database.";
      };

      repositoryUrl = mkOption {
        type = types.str;
        description = "Git repository containing the Profilarr database.";
      };

      syncStrategy = mkOption {
        type = types.ints.unsigned;
        default = 0;
        description = "Number of minutes between update checks; zero disables scheduled checks.";
      };

      autoPull = mkOption {
        type = types.bool;
        default = false;
        description = "Whether Profilarr automatically pulls available database updates.";
      };

      conflictStrategy = mkOption {
        type = types.enum [
          "override"
          "align"
          "ask"
        ];
        default = "override";
        description = "How Profilarr handles conflicts with upstream database changes.";
      };
    };
  };

  mkDatabaseScript =
    database:
    let
      payload = builtins.toJSON {
        inherit (database) name;
        repository_url = database.repositoryUrl;
        sync_strategy = database.syncStrategy;
        auto_pull = database.autoPull;
        conflict_strategy = database.conflictStrategy;
      };
    in
    ''
      DATABASE_ID=$(echo "$CURRENT_DATABASES" | ${pkgs.jq}/bin/jq -r \
        --arg name ${escapeShellArg database.name} \
        '[.[] | select(.name == $name) | .id][0] // empty')

      if [ -n "$DATABASE_ID" ]; then
        echo "Updating Profilarr database: ${database.name}"
        ${
          mkSecureCurl cfg.apiKey {
            url = "$API_URL/databases/$DATABASE_ID";
            method = "PATCH";
            headers."Content-Type" = "application/json";
            data = payload;
            extraArgs = "-fS";
          }
        } > /dev/null
      else
        echo "Linking Profilarr database: ${database.name}"
        ${
          mkSecureCurl cfg.apiKey {
            url = "$API_URL/databases";
            method = "POST";
            headers."Content-Type" = "application/json";
            data = payload;
            extraArgs = "-fS";
          }
        } > /dev/null
      fi
    '';
in
{
  options.nixflix.profilarr = {
    enable = mkEnableOption "Profilarr configuration manager for Radarr and Sonarr";

    image = mkOption {
      type = types.str;
      default = "ghcr.io/dictionarry-hub/profilarr:2.2.0";
      description = "OCI image used to run Profilarr.";
    };

    apiKey = secrets.mkSecretOption {
      description = ''
        Profilarr API key used by the declarative database setup service.
        The key must contain at least 32 characters.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "profilarr";
      description = "User that owns the Profilarr data directory and runs the app in the container.";
    };

    group = mkOption {
      type = types.str;
      default = "profilarr";
      description = "Group that owns the Profilarr data directory.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "${config.nixflix.stateDir}/profilarr";
      defaultText = literalExpression ''"''${nixflix.stateDir}/profilarr"'';
      description = "Directory containing Profilarr state and its SQLite database.";
    };

    port = mkOption {
      type = types.port;
      default = 6868;
      description = "Host port on which Profilarr listens.";
    };

    timeZone = mkOption {
      type = types.str;
      # time.timeZone is nullOr str, so `or` is not enough: it only guards a
      # missing attribute, not a null value.
      default = if config.time.timeZone != null then config.time.timeZone else "Etc/UTC";
      defaultText = literalExpression ''config.time.timeZone or "Etc/UTC"'';
      example = "America/New_York";
      description = "Time zone Profilarr uses for scheduled jobs.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the Profilarr port in the firewall.";
    };

    subdomain = mkOption {
      type = types.str;
      default = "profilarr";
      description = "Subdomain prefix for reverse proxy routing.";
    };

    reverseProxy.expose = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to expose Profilarr through the reverse proxy.";
    };

    databases = mkOption {
      type = types.listOf databaseType;
      default = [
        {
          name = "Dictionarry";
          repositoryUrl = "https://github.com/Dictionarry-Hub/database";
          syncStrategy = 60;
          autoPull = true;
        }
        {
          name = "trash-pcd";
          repositoryUrl = "https://github.com/Dictionarry-Hub/trash-pcd";
          syncStrategy = 1440;
          autoPull = true;
        }
      ];
      description = "Profilarr databases to link and keep configured.";
    };
  };

  config = mkIf (config.nixflix.enable && cfg.enable) (mkMerge [
    (mkVirtualHost {
      inherit hostname;
      inherit (cfg.reverseProxy) expose;
      inherit (cfg) port;
      websocketUpgrade = true;
    })
    {
      assertions = optional (!secrets.isSecretRef cfg.apiKey) {
        assertion = stringLength cfg.apiKey >= 32;
        message = "nixflix.profilarr.apiKey must contain at least 32 characters.";
      };

      users.users.${cfg.user} = {
        inherit (cfg) group;
        isSystemUser = true;
        home = cfg.dataDir;
      };

      users.groups.${cfg.group} = { };

      # The container entrypoint runs as root and chowns /config to PUID:PGID
      # before dropping privileges, so the directory has to be owned by the
      # same user the container is told to use. Otherwise systemd-tmpfiles and
      # the entrypoint fight over the owner on every start.
      systemd.tmpfiles.settings."10-profilarr".${cfg.dataDir}.d = {
        mode = "0750";
        inherit (cfg) user group;
      };

      virtualisation.oci-containers.containers.profilarr = {
        inherit (cfg) image;
        ports = [
          "${if config.nixflix.reverseProxy.enable then "127.0.0.1" else "0.0.0.0"}:${toString cfg.port}:6868"
        ];
        volumes = [ "${cfg.dataDir}:/config" ];
        environment = {
          AUTH = "on";
          TZ = cfg.timeZone;
        };
        environmentFiles = [ "/run/profilarr/container.env" ];
      };

      systemd.services.${containerService} = {
        after = [ "nixflix-setup-dirs.service" ] ++ config.nixflix.serviceDependencies;
        requires = [ "nixflix-setup-dirs.service" ] ++ config.nixflix.serviceDependencies;
        preStart = mkBefore ''
          install -d -m 0700 /run/profilarr
          API_KEY=${secrets.toShellValue cfg.apiKey}
          printf 'PROFILARR_API_KEY=%s\n' "$API_KEY" > /run/profilarr/container.env
          # PUID and PGID are resolved at runtime so the module does not have
          # to pin a static uid for the profilarr user.
          printf 'PUID=%s\n' "$(${pkgs.coreutils}/bin/id -u ${escapeShellArg cfg.user})" \
            >> /run/profilarr/container.env
          printf 'PGID=%s\n' "$(${pkgs.coreutils}/bin/id -g ${escapeShellArg cfg.user})" \
            >> /run/profilarr/container.env
          chmod 0600 /run/profilarr/container.env
        '';
      };

      systemd.services.profilarr-databases = {
        description = "Configure Profilarr databases via API";
        after = [ "${containerService}.service" ];
        requires = [ "${containerService}.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };

        script = ''
          set -eu
          API_URL=${escapeShellArg apiUrl}

          ${pkgs.curl}/bin/curl --retry 60 --retry-delay 2 --retry-connrefused \
            -fsS "$API_URL/health" > /dev/null

          CURRENT_DATABASES=$(${
            mkSecureCurl cfg.apiKey {
              url = "$API_URL/databases";
              extraArgs = "-fS";
            }
          })

          ${concatMapStringsSep "\n" mkDatabaseScript cfg.databases}
        '';
      };

      networking.firewall.allowedTCPPorts = optional cfg.openFirewall cfg.port;
    }
  ]);
}
