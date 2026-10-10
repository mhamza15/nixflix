{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.nixflix.recyclarr;

  yaml = pkgs.formats.yaml { };
  json = pkgs.formats.json { };

  stateDir = "/var/lib/recyclarr";

  services = [
    "sonarr"
    "radarr"
  ];

  # Recyclarr reads a `custom-formats` provider as a flat folder of JSON files.
  # Each format is written under its own trash ID, which Recyclarr keys it by.
  customFormatDir =
    service:
    pkgs.linkFarm "recyclarr-${service}-custom-formats" (
      map (format: {
        name = "${format.trash_id}.json";
        path = json.generate "${format.trash_id}.json" format;
      }) cfg.customFormats.${service}
    );

  customFormatProviders = concatMap (
    service:
    optional (cfg.customFormats.${service} != [ ]) {
      name = "nixflix-${service}-custom-formats";
      type = "custom-formats";
      path = "${customFormatDir service}";
      inherit service;
    }
  ) services;

  # The generated providers go last. Recyclarr gives the last provider
  # precedence, so a format declared here wins over a guide format of the same
  # trash ID.
  settings =
    cfg.settings
    // optionalAttrs (customFormatProviders != [ ]) {
      resource_providers = (cfg.settings.resource_providers or [ ]) ++ customFormatProviders;
    };

  settingsFile = yaml.generate "recyclarr-settings.yml" settings;

  allCustomFormats = concatMap (service: cfg.customFormats.${service}) services;
in
{
  options.nixflix.recyclarr = {
    settings = mkOption {
      inherit (yaml) type;
      default = { };
      example = literalExpression ''
        {
          resource_providers = [
            {
              name = "my-guides";
              type = "trash-guides";
              clone_url = "https://github.com/me/guides.git";
            }
          ];
        }
      '';
      description = ''
        Recyclarr `settings.yml`, as a Nix attribute set. It holds settings that
        apply to every instance, such as resource providers, notifications, and
        the log janitor. Formats in {option}`nixflix.recyclarr.customFormats`
        are appended to `resource_providers`.

        See the [settings reference](https://recyclarr.dev/reference/settings/).
      '';
    };

    customFormats = genAttrs services (
      service:
      mkOption {
        type = types.listOf json.type;
        default = [ ];
        example = literalExpression ''
          [
            {
              trash_id = "my-seadex-best";
              name = "SeaDex Best";
              specifications = [
                {
                  name = "Freeleech25";
                  implementation = "IndexerFlagSpecification";
                  negate = false;
                  required = true;
                  fields.value = 64;
                }
              ];
            }
          ]
        '';
        description = ''
          Custom formats for ${service} that are not in the TRaSH Guides, in the
          guide's JSON format. Each format needs a unique `trash_id` and a `name`.
          They become a local resource provider, so an instance syncs one the
          same way as a guide format, by listing its `trash_id` under
          `custom_formats` in {option}`nixflix.recyclarr.config`.
        '';
      }
    );
  };

  config = mkIf (config.nixflix.enable && cfg.enable) {
    assertions = [
      {
        assertion = all (format: format ? trash_id && format ? name) allCustomFormats;
        message = "nixflix.recyclarr.customFormats: every format must set `trash_id` and `name`";
      }
      {
        assertion = all (
          service:
          let
            ids = map (format: format.trash_id or null) cfg.customFormats.${service};
          in
          length ids == length (unique ids)
        ) services;
        message = "nixflix.recyclarr.customFormats: trash IDs must be unique per service";
      }
    ];

    # Link the settings into the state directory before each sync. Recyclarr
    # reads settings.yml from its config directory, which the NixOS module
    # sets to the state directory. A link left by an earlier generation is
    # removed once no settings remain.
    systemd.services.recyclarr.preStart = mkAfter (
      if settings != { } then
        ''
          ln -sfn ${settingsFile} ${stateDir}/settings.yml
        ''
      else
        ''
          if [ -L ${stateDir}/settings.yml ]; then
            rm ${stateDir}/settings.yml
          fi
        ''
    );
  };
}
