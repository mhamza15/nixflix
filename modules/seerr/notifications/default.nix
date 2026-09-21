{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  secrets = import ../../../lib/secrets { inherit lib; };
  inherit (config) nixflix;
  cfg = nixflix.seerr;

  authUtil = import ../authUtil.nix {
    inherit
      lib
      pkgs
      cfg
      ;
  };
  baseUrl = "http://${cfg.connectionAddress}:${toString cfg.port}";

  # Notification agents Seerr exposes under /api/v1/settings/notifications.
  agents = [
    "discord"
    "email"
    "gotify"
    "ntfy"
    "pushbullet"
    "pushover"
    "slack"
    "telegram"
    "webhook"
    "webpush"
  ];

  # Bit for each event, from the Notification enum in
  # server/lib/notifications/index.ts of the Seerr repository. The test
  # event (32) is left out on purpose.
  eventBits = {
    mediaPending = 2;
    mediaApproved = 4;
    mediaAvailable = 8;
    mediaFailed = 16;
    mediaDeclined = 64;
    mediaAutoApproved = 128;
    issueCreated = 256;
    issueComment = 512;
    issueResolved = 1024;
    issueReopened = 2048;
    mediaAutoRequested = 4096;
  };

  eventsToBitmask = events: foldl' (acc: event: acc + eventBits.${event}) 0 events;

  optionValueType = types.oneOf [
    types.str
    types.bool
    types.int
    (types.submodule {
      options._secret = mkOption {
        type = types.oneOf [
          types.str
          types.path
        ];
        description = "Path to a file containing the secret value";
      };
    })
  ];

  agentType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether Seerr sends through this agent.";
      };

      embedPoster = mkOption {
        type = types.bool;
        default = true;
        description = "Attach the media poster to the notification where the agent supports it.";
      };

      events = mkOption {
        type = types.listOf (types.enum (attrNames eventBits));
        default = attrNames eventBits;
        defaultText = literalExpression "every event except the test notification";
        description = "Events this agent is subscribed to.";
      };

      options = mkOption {
        type = types.attrsOf optionValueType;
        default = { };
        example = literalExpression ''
          {
            webhookUrl._secret = "/run/secrets/discord-webhook";
            botUsername = "Seerr";
            enableMentions = false;
          }
        '';
        description = ''
          Agent settings, sent as the `options` object. Keys follow the agent,
          for example `webhookUrl`, `botUsername`, `botAvatarUrl` and
          `enableMentions` for Discord, `accessToken` and `userToken` for
          Pushover. Any string value may be `{ _secret = "/path"; }` and is read
          from that file at runtime.
        '';
      };
    };
  };

  # Build the POST body for one agent in jq so secret values come from their
  # files at runtime rather than from the Nix store.
  mkAgentScript =
    agent: agentCfg:
    let
      payload = {
        enabled = agentCfg.enable;
        inherit (agentCfg) embedPoster;
        types = eventsToBitmask agentCfg.events;
        inherit (agentCfg) options;
      };
      plainJson = builtins.toJSON (secrets.stripSecretRefs payload);
      jqSecrets = secrets.mkNestedJqSecretArgs payload;
      filter = concatStringsSep " | " ([ "$plain" ] ++ jqSecrets.assignments);
    in
    ''
      echo "Configuring Seerr ${agent} notifications..."

      PAYLOAD=$(${pkgs.jq}/bin/jq -n \
        ${jqSecrets.flagsString} \
        --argjson plain ${escapeShellArg plainJson} \
        ${escapeShellArg filter})

      RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST \
        ${authUtil.curlAuthArgs} \
        -H "Content-Type: application/json" \
        --data-binary "$PAYLOAD" \
        -w "\n%{http_code}" \
        "$BASE_URL/api/v1/settings/notifications/${agent}")

      HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
      if [ "$HTTP_CODE" != "200" ]; then
        echo "Failed to configure ${agent} notifications (HTTP $HTTP_CODE)" >&2
        echo "$RESPONSE" | head -n-1 >&2
        exit 1
      fi
    '';
in
{
  options.nixflix.seerr.notifications = mkOption {
    type = types.attrsOf agentType;
    default = { };
    example = literalExpression ''
      {
        discord.options = {
          webhookUrl._secret = "/run/secrets/discord-webhook";
          botUsername = "Seerr";
        };
      }
    '';
    description = ''
      Notification agents to configure, keyed by agent name. One of
      ${concatMapStringsSep ", " (a: "`${a}`") agents}. Each agent's settings are
      replaced in full on every activation, so an agent not listed here keeps
      whatever was set in the UI.
    '';
  };

  config = mkIf (nixflix.enable && cfg.enable && cfg.notifications != { }) {
    assertions = [
      {
        assertion = all (agent: elem agent agents) (attrNames cfg.notifications);
        message = "nixflix.seerr.notifications keys must be one of: ${concatStringsSep ", " agents}.";
      }
    ];

    systemd.services.seerr-notifications = {
      description = "Configure Seerr notification agents";
      after = [ "seerr-setup.service" ];
      requires = [ "seerr-setup.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        set -euo pipefail

        BASE_URL="${baseUrl}"

        source ${authUtil.authScript}

        ${concatStringsSep "\n" (mapAttrsToList mkAgentScript cfg.notifications)}

        echo "Seerr notification agents configured"
      '';
    };
  };
}
