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
  inherit (import ./utils.nix { inherit lib pkgs serviceName; }) usesMediaDirs;
  inherit (import ../../lib/unit-paths.nix { inherit lib; }) quotePaths;
  inherit (config.nixflix) globals;
in
{
  options.nixflix.${serviceName} = optionalAttrs usesMediaDirs {
    mediaDirs = mkOption {
      type = types.listOf types.path;
      default = [ ];
      defaultText = literalExpression ''[config.nixflix.mediaDir + "/<media-type>"]'';
      description = "List of media directories to create and manage";
    };

    manageMediaDirs = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to create `mediaDirs` and set their owner and mode with
        systemd-tmpfiles. Disable this when the directories live on a
        filesystem that owns them itself, such as a network or FUSE mount
        where a chown fails and takes the whole tmpfiles run down with it.
        The service still gets read-write access to the directories.
      '';
    };
  };

  config = mkIf (usesMediaDirs && config.nixflix.enable && cfg.enable) {
    systemd.tmpfiles.settings."10-${serviceName}" = mkIf cfg.manageMediaDirs (
      lib.mergeAttrsList (
        map (mediaDir: {
          "${mediaDir}".d = {
            inherit (globals.libraryOwner) user group;
            mode = "0775";
          };
        }) cfg.mediaDirs
      )
    );

    systemd.services.${serviceName}.serviceConfig = {
      SupplementaryGroups = [ globals.libraryOwner.group ];
      ReadWritePaths = quotePaths (cfg.mediaDirs ++ [ config.nixflix.downloadsDir ]);
    };
  };
}
