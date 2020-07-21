{ lib, pkgs
# TODO: temporary, to make overwriting yarn2nix easy
# TODO: remove static building once RPATHs are fixed
, yarn2nix ? pkgs.haskell.lib.justStaticExecutables
               pkgs.haskellPackages.yarn2nix
}:

let
  # Build an attrset of node dependencies suitable for the `nodeBuildInputs`
  # argument of `buildNodePackage`. The input is an overlay
  # of node packages that call `_buildNodePackage`, like in the
  # files generated by `yarn2nix`.
  # It is possible to just call it with a generated file, like so:
  # `buildNodeDeps (pkgs.callPackage ./npm-deps.nix {})`
  # You can also use `lib.composeExtensions` to override packages
  # in the set:
  # ```
  # buildNodeDeps (lib.composeExtensions
  #   (pkgs.callPackage ./npm-deps.nix {})
  #   (self: super: { pkg = super.pkg.override {…}; }))
  # ```
  # TODO: should _buildNodePackage be fixed in here?
  buildNodeDeps = nodeDeps: lib.fix
    (lib.extends
      nodeDeps
      (self: {
        # The actual function building our packages.
        # type: { key: String | { scope: String, name: String }
        #       , <other arguments of ./buildNodePackage.nix> }
        # Wraps the invocation in the fix point, to construct the
        # list of { key, drv } needed by buildNodePackage
        # from the templates.
        # It is basically a manual paramorphism, carrying parts of the
        # information of the previous layer (the original package key).
        # TODO: move that function out of the package set
        #       and get nice self/super scoping right
        _buildNodePackage = { key, ... }@args:
          # To keep the generated files shorter, we allow keys to
          # be represented as strings if they have no scopes.
          # This is the only place where this is accepted,
          # but hacky nonetheless. Probably fix with above TODO.
          let key' = if builtins.isString key
                     then { scope = ""; name = key; }
                     else key;
          in { key = key';
               drv = buildNodePackage (args // { key = key'; }); };
      }));

  # Build a package template generated by the `yarn2nix --template`
  # utility from a yarn package. The first input is the path to the
  # template nix file, the second input is all node dependencies
  # needed by the template, in the form generated by `buildNodeDeps`.
  callTemplate = yarn2nixTemplate: allDeps:
    let t = pkgs.callPackage yarn2nixTemplate {} allDeps;
    in t // {
      meta = t.meta // {
        license = npmSpdxLicenseToNixpkgsLicense t.meta.license;
      };
    };

  buildNodePackage = import ./buildNodePackage.nix {
    inherit linkNodeDeps yarn2nix buildCallDeps
            buildTemplate callTemplate buildNodeDeps;
    inherit (pkgs) stdenv nodejs;
  };

  # Link together a `node_modules` folder that can be used
  # by npm’s module system to call dependencies.
  # Also link executables of all dependencies into `.bin`.
  # TODO: copy manpages & docs as well
  # type: { name: String
  #       , dependencies: ListOf { key: { scope: String, name: String }
  #                              , drv : Drv } }
  #       -> Drv
  linkNodeDeps = {name, dependencies}:
    pkgs.runCommand ("${name}-node_modules") {
      # This just creates a simple link farm, which should be pretty fast,
      # saving us from additional hydra requests for potentially hundreds
      # of packages.
      allowSubstitutes = false;
      # Also tell Hydra it’s not worth copying to a builder.
      preferLocalBuild = true;
    } ''
      mkdir -p $out/.bin
      ${lib.concatMapStringsSep "\n"
        (dep:
          let
            hasScope = dep.key.scope != "";
            # scoped packages get another subdirectory for their scope (`@scope/`)
            parentfolder = if hasScope
              then "$out/@${dep.key.scope}"
              else "$out";
            subfolder = "${parentfolder}/${dep.key.name}";
          in ''
            echo "linking node dependency ${formatKey dep.key}"
            ${ # we need to create the scope folder, otherwise ln fails
               lib.optionalString hasScope ''mkdir -p "${parentfolder}"'' }
            ln -sT ${dep.drv} "${subfolder}"
            ${yarn2nix}/bin/node-package-tool \
              link-bin \
              --to=$out/.bin \
              --package=${subfolder}
          '')
        dependencies}
    '';

  # Filter out files/directories with one of the given prefix names
  # from the given path.
  # type: ListOf File -> Path -> Drv
  removePrefixes = prfxs: path:
    let
      hasPrefix = file: prfx: lib.hasPrefix ((builtins.toPath path) + "/" + prfx) file;
      hasAnyPrefix = file: lib.any (hasPrefix file) prfxs;
    in
      builtins.filterSource (file: _: ! (hasAnyPrefix file)) path;

  # Build nix expression of dependencies based on given `yarnLock`
  # and directly `callPackage` it. Using this can avoid the need to
  # check in a generated nix expression. The resulting attrSet can
  # be used as input for `buildNodeDeps`:
  #
  # ```
  # buildNodeDeps (buildCallDeps { yarnLock = ./yarn.lock; })
  # ```
  buildCallDeps = { name ? "npm-deps.nix", yarnLock }:
    pkgs.callPackage (pkgs.runCommand name {
      # faster to build locally, see also note at linkNodeDeps
      allowSubstitutes = false;
      preferLocalBuild = true;
    } ''
      ${yarn2nix}/bin/yarn2nix ${yarnLock} > $out
    '') { };

  # Build nix expression containing the package template for a
  # given `packageJson`, eliminating the need to check in an
  # automatically generated file. Could be used like this:
  #
  # ```
  # callTemplate (buildTemplate { packageJson = ./package.json; })
  #              (buildNodeDeps (buildCallDeps { yarnLock = ./yarn.lock; }))
  # ```
  buildTemplate = { name ? "template.nix", packageJson }:
    pkgs.runCommand name {
      # faster to build locally, see also note at linkNodeDeps
      allowSubstitutes = false;
      preferLocalBuild = true;
    } ''
      ${yarn2nix}/bin/yarn2nix --template ${packageJson} > $out
    '';

  # format a package key of { scope: String, name: String }
  formatKey = { scope, name }:
    if scope == ""
    then name
    else "@${scope}/${name}";

  # Helper function to convert from a SPDX license string as found
  # in package.json (https://docs.npmjs.com/files/package.json#license)
  # to a nix license attrSet as found in lib.licenses.
  #
  # Implementation is taken from yarn2nix-moretea.
  # It does not support SPDX expression syntax.
  # https://github.com/NixOS/nixpkgs/blob/master/pkgs/development/tools/yarn2nix-moretea/yarn2nix/default.nix#L35-L42
  npmSpdxLicenseToNixpkgsLicense = licstr:
    if licstr == "UNLICENSED" then
      lib.licenses.unfree
    else
      lib.findFirst
        (l: l ? spdxId && l.spdxId == licstr)
        { shortName = licstr; }
        (builtins.attrValues lib.licenses);

in {
  inherit buildNodeDeps linkNodeDeps buildNodePackage
          callTemplate removePrefixes buildCallDeps
          buildTemplate;
}
