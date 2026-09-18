{ serviceName }:
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.${serviceName};
  inherit (import ./utils.nix { inherit lib pkgs serviceName; })
    usesMediaDirs
    capitalizedName
    mkSecureCurl
    mkWaitForApiScript
    ;

  mappingType = types.submodule {
    options = {
      host = mkOption {
        type = types.str;
        example = "seedbox.example.com";
        description = "Download client host the mapping applies to. Must match the host of a download client.";
      };

      remotePath = mkOption {
        type = types.str;
        example = "/home/user/downloads/";
        description = "Path the download client reports, as seen on its own machine.";
      };

      localPath = mkOption {
        type = types.str;
        example = "/mnt/seedbox/downloads/";
        description = "Path where this host sees the same files.";
      };
    };
  };

  # Sonarr and Radarr key a mapping by host and remote path. A pair is written
  # once and updated in place when the local path changes.
  mappingKey = m: "${m.host}|${m.remotePath}";
in
{
  options.nixflix.${serviceName}.config = optionalAttrs usesMediaDirs {
    remotePathMappings = mkOption {
      type = types.listOf mappingType;
      default = [ ];
      description = ''
        Remote path mappings created via the API /remotepathmapping endpoint.
        A mapping tells the service where to find downloads a remote download
        client reports under its own paths. Mappings not listed here are
        removed.
      '';
      example = literalExpression ''
        [
          {
            host = "seedbox.example.com";
            remotePath = "/home/user/downloads/complete/tv/";
            localPath = "/mnt/seedbox/downloads/tv/";
          }
        ]
      '';
    };
  };

  config =
    mkIf
      (
        usesMediaDirs
        && config.nixflix.enable
        && cfg.enable
        && cfg.config.apiKey != null
        && cfg.config.remotePathMappings != [ ]
      )
      {
        systemd.services."${serviceName}-remotepathmappings" = {
          description = "Configure ${serviceName} remote path mappings via API";
          after = [ "${serviceName}-config.service" ] ++ config.nixflix.serviceDependencies;
          requires = [ "${serviceName}-config.service" ] ++ config.nixflix.serviceDependencies;
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStartPre = mkWaitForApiScript serviceName cfg.config;
          };

          script = ''
            set -eu

            BASE_URL="http://${cfg.config.hostConfig.bindAddress}:${builtins.toString cfg.config.hostConfig.port}${cfg.config.hostConfig.urlBase}/api/${cfg.config.apiVersion}"

            echo "Fetching remote path mappings..."
            MAPPINGS=$(${
              mkSecureCurl cfg.config.apiKey {
                url = "$BASE_URL/remotepathmapping";
                extraArgs = "-Sf";
              }
            } 2>/dev/null)

            CONFIGURED_KEYS=$(cat <<'EOF'
            ${builtins.toJSON (map mappingKey cfg.config.remotePathMappings)}
            EOF
            )

            echo "Removing remote path mappings not in configuration..."
            echo "$MAPPINGS" | ${pkgs.jq}/bin/jq -r '.[] | @json' | while IFS= read -r mapping; do
              KEY=$(echo "$mapping" | ${pkgs.jq}/bin/jq -r '"\(.host)|\(.remotePath)"')
              ID=$(echo "$mapping" | ${pkgs.jq}/bin/jq -r '.id')

              if ! echo "$CONFIGURED_KEYS" | ${pkgs.jq}/bin/jq -e --arg key "$KEY" 'index($key)' >/dev/null 2>&1; then
                echo "Deleting remote path mapping not in config: $KEY (ID: $ID)"
                ${
                  mkSecureCurl cfg.config.apiKey {
                    url = "$BASE_URL/remotepathmapping/$ID";
                    method = "DELETE";
                    extraArgs = "-Sf";
                  }
                } >/dev/null 2>&1 || echo "Warning: Failed to delete remote path mapping $KEY"
              fi
            done

            ${concatMapStringsSep "\n" (
              mapping:
              let
                key = mappingKey mapping;
                mappingJson = builtins.toJSON mapping;
              in
              ''
                EXISTING=$(echo "$MAPPINGS" | ${pkgs.jq}/bin/jq -c --arg host ${escapeShellArg mapping.host} --arg remote ${escapeShellArg mapping.remotePath} '.[] | select(.host == $host and .remotePath == $remote)' 2>/dev/null || true)

                if [ -z "$EXISTING" ]; then
                  echo "Creating remote path mapping: ${key}"
                  ${
                    mkSecureCurl cfg.config.apiKey {
                      url = "$BASE_URL/remotepathmapping";
                      method = "POST";
                      headers = {
                        "Content-Type" = "application/json";
                      };
                      data = mappingJson;
                      extraArgs = "-Sf";
                    }
                  } > /dev/null
                  echo "Remote path mapping created: ${key}"
                elif [ "$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -r '.localPath')" != ${escapeShellArg mapping.localPath} ]; then
                  ID=$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -r '.id')
                  UPDATED=$(echo "$EXISTING" | ${pkgs.jq}/bin/jq -c --arg local ${escapeShellArg mapping.localPath} '.localPath = $local')
                  echo "Updating remote path mapping: ${key}"
                  ${
                    mkSecureCurl cfg.config.apiKey {
                      url = "$BASE_URL/remotepathmapping/$ID";
                      method = "PUT";
                      headers = {
                        "Content-Type" = "application/json";
                      };
                      data = "$UPDATED";
                      extraArgs = "-Sf";
                    }
                  } > /dev/null
                  echo "Remote path mapping updated: ${key}"
                else
                  echo "Remote path mapping already exists: ${key}"
                fi
              ''
            ) cfg.config.remotePathMappings}

            echo "${capitalizedName} remote path mappings configuration complete"
          '';
        };
      };
}
