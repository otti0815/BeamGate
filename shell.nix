{ pkgs ? import <nixpkgs> {} }:
let
  lib = pkgs.lib;
in
pkgs.mkShell {
  packages =
    with pkgs;
    [
      erlang_26
      beam.packages.erlang_26.elixir_1_16
      rebar3
      git
      curl
      jq
      openssl
      cacert
    ]
    ++ lib.optionals stdenv.isLinux [ inotify-tools ]
    ++ lib.optionals stdenv.isDarwin [ fswatch ];

  shellHook = ''
    export MIX_ENV=dev
    export LANG=en_US.UTF-8
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    echo "BeamGate nix-shell ready."
    echo "Next: mix deps.get && mix phx.server"
  '';
}
