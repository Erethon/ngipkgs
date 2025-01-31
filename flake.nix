{
  description = "NGIpkgs";

  inputs.dream2nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.dream2nix.url = "github:nix-community/dream2nix";
  inputs.flake-utils.inputs.systems.follows = "systems";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.hydra.url = "github:NixOS/hydra/nix-next";
  inputs.nixpkgs-stable.url = "github:NixOS/nixpkgs/nixos-23.11";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  inputs.pre-commit-hooks.inputs.flake-utils.follows = "flake-utils";
  inputs.pre-commit-hooks.inputs.nixpkgs-stable.follows = "nixpkgs-stable";
  inputs.pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
  inputs.pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
  inputs.rust-overlay.inputs.flake-utils.follows = "flake-utils";
  inputs.rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  inputs.rust-overlay.url = "github:oxalica/rust-overlay";
  inputs.sops-nix.inputs.nixpkgs-stable.follows = "nixpkgs-stable";
  inputs.sops-nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.sops-nix.url = "github:Mic92/sops-nix";

  # See <https://github.com/ngi-nix/ngipkgs/issues/24> for plans to support Darwin.
  inputs.systems.url = "github:nix-systems/default-linux";

  outputs = {
    hydra,
    self,
    nixpkgs,
    flake-utils,
    sops-nix,
    rust-overlay,
    pre-commit-hooks,
    dream2nix,
    ...
  }: let
    # Take Nixpkgs' lib and update it with the definitions in ./lib.nix
    lib = nixpkgs.lib.recursiveUpdate nixpkgs.lib (import ./lib.nix {inherit (nixpkgs) lib;});

    inherit
      (builtins)
      mapAttrs
      attrValues
      isPath
      ;

    inherit
      (lib)
      concatMapAttrs
      mapAttrs'
      foldr
      recursiveUpdate
      nameValuePair
      nixosSystem
      filterAttrs
      attrByPath
      mapAttrByPath
      flattenAttrsDot
      flattenAttrsSlash
      ;

    importProjects = {
      pkgs ? {},
      sources ? {
        configurations = rawNixosConfigs;
        modules = extendedModules;
      },
    }:
      import ./projects {inherit lib pkgs sources;};

    # Functions to ease access of imported projects, by "picking" certain paths.
    pick = rec {
      packages = mapAttrByPath ["packages"] {};
      modulePaths = x:
        concatMapAttrs (n: v:
          if isPath v
          then {${n} = v;}
          else {})
        (modules x);
      modules = projects: flattenAttrsDot (lib.foldl recursiveUpdate {} (attrValues (mapAttrByPath ["nixos" "modules"] {} projects)));
      tests = mapAttrByPath ["nixos" "tests"] {};
      configurations = projects: mapAttrs (_: v: mapAttrs (_: v: v.path) v) (mapAttrByPath ["nixos" "configurations"] {} projects);
    };

    importPackages = pkgs: let
      nixosTests = pick.tests (importProjects {pkgs = pkgs // allPackages;});

      callPackage = pkgs.newScope (
        allPackages // {inherit callPackage nixosTests;}
      );

      allPackages = import ./pkgs/by-name {
        inherit (pkgs) lib;
        inherit callPackage dream2nix pkgs;
      };
    in
      allPackages;

    importNixpkgs = system: overlays:
      import nixpkgs {inherit system overlays;};

    rawNixosConfigs = flattenAttrsSlash (pick.configurations (importProjects {}));

    # Attribute set containing all modules obtained via `inputs` and defined
    # in this flake towards definition of `nixosConfigurations` and `nixosTests`.
    extendedModules =
      self.nixosModules
      // {
        sops-nix = sops-nix.nixosModules.default;
      };

    nixosConfigurations =
      mapAttrs
      (_: config: nixosSystem {modules = [config ./dummy.nix] ++ attrValues extendedModules;})
      rawNixosConfigs;

    eachDefaultSystemOutputs = flake-utils.lib.eachDefaultSystem (system: let
      pkgs = importNixpkgs system [rust-overlay.overlays.default];

      importedProjects = importProjects {
        pkgs = pkgs // importPack;
      };

      toplevel = name: config: nameValuePair "nixosConfigs/${name}" config.config.system.build.toplevel;

      importPack = importPackages pkgs;

      optionsDoc = pkgs.nixosOptionsDoc {
        options =
          (import (nixpkgs + "/nixos/lib/eval-config.nix") {
            inherit system;
            modules =
              [
                {
                  networking = {
                    domain = "invalid";
                    hostName = "options";
                  };

                  system.stateVersion = "23.05";
                }
              ]
              ++ attrValues self.nixosModules;
          })
          .options;
      };
    in rec {
      packages =
        importPack
        // {
          overview = import ./overview {
            inherit lib pkgs self;
            projects = importedProjects;
            options = optionsDoc.optionsNix;
          };

          options =
            pkgs.runCommand "options.json" {
              build = optionsDoc.optionsJSON;
            } ''
              mkdir $out
              cp $build/share/doc/nixos/options.json $out/
            '';
        };

      checks =
        mapAttrs' toplevel nixosConfigurations
        // {
          pre-commit = pre-commit-hooks.lib.${system}.run {
            src = ./.;
            hooks = {
              actionlint.enable = true;
              alejandra.enable = true;
            };
          };
          makemake = self.nixosConfigurations.makemake.config.system.build.toplevel;
        };

      devShells.default = pkgs.mkShell {
        inherit (checks.pre-commit) shellHook;
        buildInputs = checks.pre-commit.enabledPackages;
      };

      formatter = pkgs.writeShellApplication {
        name = "formatter";
        text = ''
          # shellcheck disable=all
          shell-hook () {
            ${checks.pre-commit.shellHook}
          }

          shell-hook
          pre-commit run --all-files
        '';
      };
    });

    x86_64-linuxOutputs = let
      system = flake-utils.lib.system.x86_64-linux;
      pkgs = importNixpkgs system [self.overlays.default];
      # Dream2nix is failing to pass through the meta attribute set.
      # As a workaround, consider packages with empty meta as non-broken.
      nonBrokenPkgs = filterAttrs (_: v: !(attrByPath ["meta" "broken"] false v)) self.packages.${system};
    in {
      # Github Actions executes `nix flake check` therefore this output
      # should only contain derivations that can built within CI.
      # See `.github/workflows/ci.yaml`.
      checks.${system} =
        # For `nix flake check` to *build* all packages, because by default
        # `nix flake check` only evaluates packages and does not build them.
        mapAttrs' (name: check: nameValuePair "packages/${name}" check) nonBrokenPkgs;

      # To generate a Hydra jobset for CI builds of all packages and tests.
      # See <https://hydra.ngi0.nixos.org/jobset/ngipkgs/main>.
      hydraJobs = let
        passthruTests = concatMapAttrs (name: value:
          if value ? passthru.tests
          then {${name} = value.passthru.tests;}
          else {})
        nonBrokenPkgs;
      in {
        packages.${system} = nonBrokenPkgs;
        tests.${system} = {
          passthru = passthruTests;
          nixos = pick.tests (importProjects {pkgs = pkgs // nonBrokenPkgs;});
        };

        nixosConfigurations.${system} =
          mapAttrs
          (name: config: config.config.system.build.toplevel)
          nixosConfigurations;
      };
    };

    systemAgnosticOutputs = {
      nixosConfigurations =
        nixosConfigurations
        // {
          makemake = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";

            modules = [
              # Use NixOS module for pinned Hydra, but note that this doesn't
              # set the package to be from that repo.  It juse uses the stock
              # `pkgs.hydra_unstable` by default.
              hydra.nixosModules.hydra

              {
                # Here, set the Hydra package to use the (complete
                # self-contained, pinning nix, nixpkgs, etc.) default Hydra
                # build. Other than this one package, those pins versions are
                # not used.
                services.hydra.package = hydra.packages.x86_64-linux.default;
              }

              ./infra/makemake/configuration.nix

              {
                #nix.registry.nixpkgs.flake = nixpkgs;
                nix.nixPath = ["nixpkgs=${nixpkgs}"];
              }
            ];
          };
        };

      nixosModules =
        {
          unbootable = ./modules/unbootable.nix;
          # The default module adds the default overlay on top of Nixpkgs.
          # This is so that `ngipkgs` can be used alongside `nixpkgs` in a configuration.
          default.nixpkgs.overlays = [self.overlays.default];
        }
        // (filterAttrs (_: v: v != null) (pick.modules (importProjects {})));

      # Overlays a package set (e.g. Nixpkgs) with the packages defined in this flake.
      overlays.default = final: prev: importPackages prev;
    };
  in
    foldr recursiveUpdate {} [
      eachDefaultSystemOutputs
      x86_64-linuxOutputs
      systemAgnosticOutputs
    ];
}
