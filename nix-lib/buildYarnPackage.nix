{ stdenv
, linkNodeDeps
, buildNodeDeps
, callPackageJson
, callYarnLock
, nodejs
, yarn2nix}:
{ src
, yarnLock
, packageJson
, buildScripts ? []
, linkBuildNodeModules ? false
, installNodeModules ? true
, installDir ? "."
, ... }@args:

assert (args ? preConfigure || args ? postConfigure) -> args ? configurePhase;

let
  lib = stdenv.lib;
  scripts = (builtins.fromJSON (builtins.readFile packageJson)).scripts;
  key = if args ? key then args.key else template.key;
  version = if args ? version then args.version else template.version;
  # TODO: scope should be more structured somehow. :(
  packageName =
    if key.scope == ""
    then "${key.name}-${version}"
    else "${key.scope}-${key.name}-${version}";
  template = (callPackageJson packageJson {})
    (buildNodeDeps (callYarnLock yarnLock {}));
  nodeModules = linkNodeDeps {
    name = packageName;
    dependencies = template.nodeBuildInputs;
  };

in stdenv.mkDerivation ((removeAttrs template [ "key" "nodeBuildInputs" ]) //
  (removeAttrs args [ "key" ]) // {
    name = packageName;
    inherit version src;

    buildInputs = [ nodejs ];

    configurePhase = args.configurePhase or "true";

    buildPhase = ''
      runHook preBuild
      ${lib.optionalString (template.nodeBuildInputs != []) ''
        export PATH="${nodeModules}/.bin:$PATH"
        ${if linkBuildNodeModules
          then ''
            ln -s ${nodeModules} ./node_modules
            export NODE_PATH="node_modules"
          ''
          else ''
            export NODE_PATH="${nodeModules}"
          ''}
        ''}
      ${lib.concatMapStringsSep "\n" (s: scripts."${s}") buildScripts}
      runHook postBuild
    '';

    # TODO: maybe we can enable tests?
    doCheck = false;

    installPhase = ''
      runHook preInstall

      # a npm package is just the tarball extracted to $out
      cp -r ${installDir} $out

      # the binaries should be executable (TODO: always on?)
      [[ -f "$out/package.json" ]] && \
        ${yarn2nix}/bin/node-package-tool \
          set-bin-exec-flag \
          --package $out

      # then a node_modules folder is created for all its dependencies
      ${lib.optionalString (template.nodeBuildInputs != [] && installNodeModules) ''
          rm -rf $out/node_modules
          ln -sT "${nodeModules}" $out/node_modules
        ''}

      runHook postInstall
    '';

    dontStrip = true; # stolen from npm2nix
})
