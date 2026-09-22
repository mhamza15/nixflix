{ config, lib, ... }:
with lib;
let
  cfg = config.nixflix;

  # Long-running services that keep files under mediaDir or downloadsDir open,
  # paired with the option that enables each.
  mediaServices = {
    sonarr = cfg.sonarr.enable;
    sonarr-anime = cfg.sonarr-anime.enable;
    radarr = cfg.radarr.enable;
    lidarr = cfg.lidarr.enable;
    jellyfin = cfg.jellyfin.enable;
    navidrome = cfg.navidrome.enable;
    qbittorrent = cfg.torrentClients.qbittorrent.enable;
    sabnzbd = cfg.usenetClients.sabnzbd.enable;
  };

  enabledServices = attrNames (filterAttrs (_: enabled: enabled) mediaServices);
in
{
  config = mkIf (cfg.enable && cfg.mountDependencies != [ ]) {
    systemd.services = genAttrs enabledServices (_: {
      after = cfg.mountDependencies;
      bindsTo = cfg.mountDependencies;
    });
  };
}
