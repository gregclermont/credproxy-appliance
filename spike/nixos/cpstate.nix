# Workspace state disk (Lima additionalDisks entry, label lima-cpstate):
# spike/mkosi's cpstate-setup, unchanged: binds /home and /var/lib/docker
# from it and keeps sshd's host key there.
{ pkgs, ... }:
{
  systemd.services.cpstate = {
    description = "Workspace state disk (home, Docker data)";
    unitConfig.DefaultDependencies = false;
    after = [ "systemd-udev-trigger.service" "local-fs-pre.target" ];
    wants = [ "systemd-udev-trigger.service" ];
    before = [ "local-fs.target" "systemd-user-sessions.service" "lima-init.service" "sshd.service" ];
    wantedBy = [ "local-fs.target" ];
    path = with pkgs; [ coreutils util-linux e2fsprogs systemd openssh ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # the tmpfs root has no /home to bind over yet
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /home";
      ExecStart = "${pkgs.bash}/bin/sh ${../mkosi/mkosi.extra/usr/libexec/cpstate-setup}";
    };
  };
}
