{
  description = "credproxy appliance VM image on NixOS (dm-verity store, direct kernel boot, Lima)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems f;
      mkSystem = system: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ];
      };
    in
    {
      nixosConfigurations = forAll mkSystem // {
        cpvm = mkSystem "x86_64-linux";
      };

      # The appliance directory credproxy reads (CREDPROXY_APPLIANCE): the
      # same layout as spike/mkosi/build.sh writes.
      packages = forAll (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          cfg = self.nixosConfigurations.${system}.config;
          top = cfg.system.build.toplevel;
          # The store partition: the toplevel's closure without the paths
          # below and what only they reference. The kernel and initrd boot
          # from beside the image (dkb/); the toplevel's links to them dangle
          # in the guest.
          storePaths = pkgs.runCommand "cpvm-store-paths" {
            __structuredAttrs = true;
            exportReferencesGraph.closure = [ top ];
            nativeBuildInputs = [ pkgs.jq ];
            root = "${top}";
            exclude = [ "${cfg.boot.kernelPackages.kernel}" "${cfg.system.build.initialRamdisk}" ];
          } ''
            jq -r '.root as $root | .exclude as $ex
              | (.closure | map({ key: .path, value: .references }) | from_entries) as $g
              | { seen: {}, todo: [ $root ] }
              | until(.todo | length == 0;
                  .todo[0] as $p | .todo |= .[1:]
                  | if .seen[$p] or ($ex | any(. == $p)) then . else .seen[$p] = true | .todo += $g[$p] end)
              | .seen | keys[]' "$NIX_ATTRS_JSON_FILE" >"''${outputs[out]}"
          '';
          image = cfg.system.build.image.overrideAttrs (prev: {
            finalPartitions = prev.finalPartitions // {
              "10-nix-store" = prev.finalPartitions."10-nix-store" // { closure = "${storePaths}"; };
            };
          });
        in
        {
          appliance = pkgs.runCommand "cpvm-appliance" { nativeBuildInputs = [ pkgs.jq ]; } ''
            mkdir -p $out/dkb
            ln -s ${image}/${cfg.image.fileName} $out/cpvm.raw
            ln -s ${top}/kernel $out/dkb/kernel
            ln -s ${top}/initrd $out/dkb/initrd
            roothash=$(jq -r '.[] | select(.label == "nix-store") | .roothash' ${image}/repart-output.json)
            [ ''${#roothash} = 64 ]
            echo "roothash=$roothash init=${top}/init $(cat ${top}/kernel-params)" >$out/dkb/kernel.cmdline
          '';
          default = self.packages.${system}.appliance;
        });
    };
}
