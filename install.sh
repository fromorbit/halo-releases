#!/bin/sh
# Installs halo (Linux x64) for the current user and gets it running: the program, a container engine (Podman, with an
# instance of Halo's own), the runtime images, the mode, a systemd service and, with accounts, the owner.
#
#   sh install.sh --mode server --host 192-168-1-50.sslip.io --owner mike   # a team server, over ssh -t (asks sudo, the owner's password)
#   HALO_OWNER_PASSWORD=... sh install.sh --mode server --host halo.example.com --owner mike --yes   # no questions
#   curl -fsSL https://<releasemap>/install.sh | sh                  # this computer only (mode local)
#
# `sh install.sh --help` lists the options. The whole script is one function that runs on the last line, so a download
# that breaks halfway runs nothing. (halo-install-script-marker-7f3a)
set -eu

usage() {
  cat <<'EOF'
install.sh: installs halo and gets it running.

  --mode local|network|server   how Halo runs (default: local, said aloud; it never asks; an existing installation keeps its mode).
                                A team: --mode server --host <domain> (or --public-url https://<domain> behind Caddy)
  --host <domain>               base domain of the addresses of spaces (server: required). No domain of your own:
                                <ip-with-dashes>.sslip.io, for example 192-168-1-50.sslip.io (wildcard DNS to that IP)
  --public-url <url>            the address people use behind a reverse proxy (Caddy), for example https://halo.example.com: Halo then
                                listens on this computer only, and the Caddy configuration is made for you (halo caddyfile).
                                Replaces --host (the host is the name of the address)
  --yes                         skip the one "Doorgaan?" before the root commands (they are still named; sudo and the owner's password
                                are still asked on a terminal)
  --engine podman|docker|auto   container engine (default auto: Podman if it is there, else a running Docker, else Podman is installed)
  --with-engine                 install the engine and what rootless needs (the default of a full install)
  --no-engine                   leave the engine, images and doctor out
  --images core|all             runtime images to build (default core: node 20 and 22; all adds PHP, which is big)
  --owner <name>                with accounts: make the owner (password from HALO_OWNER_PASSWORD; on a terminal (ssh -t) it is asked
                                when that is not set; without a terminal and without it the script stops before it does anything)
  --no-service                  no systemd service (a user unit for local, a system unit for network and server)
  --release <url>               an https (or file://) release folder: its SHA256SUMS names the Linux archive, which must match
                                (default $HALO_RELEASE_URL, else the version the channel points to)
  --channel stable|beta         which channel to follow (default stable; while there is no stable version the newest test version,
                                said aloud). beta: the newest of stable and beta. Halo remembers it for `halo update`. The channels
                                are named in kanalen.json of fromorbit/halo-releases ($HALO_KANALEN_URL, or --kanalen <https|file url>)
  --from <archive|folder|url>   an archive (.tar.gz), an unpacked folder or an https address; a SHA256SUMS next to an
                                archive or address is required unless --no-verify
  --no-verify                   install an archive without a SHA256SUMS (you vouch for it)
  --insecure-http               allow http to this computer (127.0.0.1) for a test; never remembered
  --allow-root                  run as root (a normal user with sudo is the way)
  --prefix <dir>                default ~/.local
  --no-init                     leave `halo init` out
  --binary-only                 only the program and the UI (what `halo update` uses)
  --uninstall                   removes what an install put there, the units too (not ~/.halo, your data): `halo uninstall` asks first

A full install happens when there is a terminal, or --yes, --mode or --with-engine is given; otherwise only the program and
the UI are installed and `halo init --mode local` is run once. Without a terminal nothing is asked: what is missing stops the
script at once with the line that fixes it (exit 2), and sudo that needs a password stops it too (exit 1: use ssh -t, or sudo
without a password for this user). The checksum protects against a damaged download, not against
a hostile source: trust is in https and in the release folder. Needs tar, gzip, sha256sum, curl, and sudo for the engine.
EOF
}

main() {
  prefix="${HOME}/.local"
  from=""
  release=""
  init=1
  uninstall=0
  mode=""
  host=""
  public_url=""
  yes=0
  engine=auto
  with_engine=0
  no_engine=0
  images=core
  owner=""
  no_service=0
  binary_only=0
  no_verify=0
  insecure=0
  allow_root=0
  channel=stable
  channel_named=0
  kanalen=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:?--from needs a value}"; shift 2 ;;
      --release) release="${2:?--release needs a value}"; release="${release%/}"; shift 2 ;;
      --channel) channel="${2:?--channel needs a value}"; channel_named=1; shift 2 ;;
      --kanalen) kanalen="${2:?--kanalen needs a value}"; shift 2 ;;
      --prefix) prefix="${2:?--prefix needs a value}"; shift 2 ;;
      --mode) mode="${2:?--mode needs a value}"; shift 2 ;;
      --host) host="${2:?--host needs a value}"; shift 2 ;;
      --public-url) public_url="${2:?--public-url needs a value}"; shift 2 ;;
      --engine) engine="${2:?--engine needs a value}"; shift 2 ;;
      --images) images="${2:?--images needs a value}"; shift 2 ;;
      --owner) owner="${2:?--owner needs a value}"; shift 2 ;;
      --yes|-y) yes=1; shift ;;
      --with-engine) with_engine=1; shift ;;
      --no-engine) no_engine=1; shift ;;
      --no-service) no_service=1; shift ;;
      --service) shift ;; # the default of a full install; kept so older commands still work
      --no-init) init=0; shift ;;
      --binary-only) binary_only=1; shift ;;
      --no-verify) no_verify=1; shift ;;
      --insecure-http) insecure=1; shift ;;
      --allow-root) allow_root=1; shift ;;
      --uninstall) uninstall=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) echo "install.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
    esac
  done
  case "$channel" in stable|beta) ;; *) echo "install.sh: --channel is $channel; choose stable or beta" >&2; exit 2 ;; esac
  case "$mode" in ""|local|network|server) ;; *) echo "install.sh: --mode is $mode; choose local, network or server" >&2; exit 2 ;; esac
  case "$public_url" in ""|https://*|http://*) ;; *) echo "install.sh: --public-url is $public_url; give an address like https://halo.example.com" >&2; exit 2 ;; esac
  case "$engine" in auto|podman|docker) ;; *) echo "install.sh: --engine is $engine; choose podman, docker or auto" >&2; exit 2 ;; esac
  case "$images" in core|all) ;; *) echo "install.sh: --images is $images; choose core or all" >&2; exit 2 ;; esac

  say() { printf '==> %s\n' "$*"; }
  # a terminal to ask on, also when the script itself comes in over a pipe (curl | sh)
  if (exec < /dev/tty) 2>/dev/null; then tty=1; else tty=0; fi
  # a full install (engine, mode, service, owner) when someone is there to ask or said what they want; else the program only
  full=0
  if [ "$tty" = 1 ] || [ "$yes" = 1 ] || [ -n "$mode" ] || [ "$with_engine" = 1 ]; then full=1; fi
  [ "$binary_only" = 0 ] || full=0
  data="${HALO_DATA_DIR:-$HOME/.halo}"

  unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/halo.service"
  if [ "$uninstall" = 1 ]; then
    if [ -f "$unit" ]; then
      systemctl --user disable --now halo.service >/dev/null 2>&1 || true
      rm -f "$unit"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    if [ -f /etc/systemd/system/halo.service ]; then
      echo "The system unit /etc/systemd/system/halo.service needs root to remove (sudo)."
      sudo systemctl disable --now halo.service || { echo "install.sh: could not stop the service; nothing was removed. Try: sudo systemctl disable --now halo.service" >&2; exit 1; }
      sudo rm -f /etc/systemd/system/halo.service && sudo systemctl daemon-reload || true
    fi
    rm -f "$prefix/bin/halo" "$prefix/bin/halo.prev"
    rm -rf "$prefix/share/halo"
    echo "halo removed from $prefix (your data in $data is untouched; halo uninstall --purge removes it too)."
    return 0
  fi

  if [ "$(id -u)" = 0 ] && [ "$allow_root" = 0 ]; then
    echo "install.sh: this is for a normal user with sudo, not for root: Halo, its engine and its service run as that user. Log in as that user and run it again (--allow-root if you really mean root)." >&2
    exit 2
  fi
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64) ;;
    *) echo "install.sh: this installer is for Linux x64 only (this is $(uname -s) $(uname -m)). Windows: unpack the .zip." >&2; exit 1 ;;
  esac

  # What an installation that exists says, read once (it is never overwritten from here).
  have_mode=""
  have_host=""
  if [ -f "$data/install.json" ]; then
    have_mode="$(grep -o '"mode": *"[a-z]*"' "$data/install.json" | cut -d'"' -f4 || true)"
    have_host="$(grep -o '"host": *"[^"]*"' "$data/install.json" | cut -d'"' -f4 || true)"
  fi
  eff_mode="${have_mode:-${mode:-local}}"

  # Everything that is missing is found out here, before anything is downloaded or installed, and never asked: a person on
  # ssh -t answers sudo (the system) and the password of the owner; nothing else is a question.
  if [ "$full" = 1 ]; then
    if [ "$init" = 1 ] && [ -z "$have_mode" ] && [ "$eff_mode" = server ] && [ -z "$host" ] && [ -z "$public_url" ]; then
      echo "install.sh: a server needs its own domain. Run: sh install.sh --mode server --host <domain> (no domain of your own: --host <ip-with-dashes>.sslip.io, for example 192-168-1-50.sslip.io)" >&2
      exit 2
    fi
    if [ -n "$owner" ] && [ "$eff_mode" = local ] && [ -z "$have_mode" ]; then
      echo "install.sh: --owner is for accounts, and mode local has none. Use --mode server --host <domain> (or --mode network)." >&2
      exit 2
    fi
    if [ -n "$owner" ] && [ "$eff_mode" != local ] && [ -z "${HALO_OWNER_PASSWORD:-}" ] && [ "$tty" = 0 ]; then
      echo "install.sh: --owner $owner needs a password and there is no terminal to ask on. Run it with ssh -t, or give it in the environment: HALO_OWNER_PASSWORD=\"\$(cat ~/.halo-owner)\" sh install.sh ... (at least 10 characters)" >&2
      exit 2
    fi
    need_sudo=0
    if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1; then
      [ "$no_engine" = 1 ] || need_sudo=1
      { [ "$eff_mode" = local ] || [ "$no_service" = 1 ]; } || need_sudo=1
    fi
    if [ "$need_sudo" = 1 ] && ! sudo -n true 2>/dev/null; then
      if [ "$tty" = 1 ]; then
        say "Halo needs sudo for the engine and the service: sudo asks for your password, once"
        sudo -v < /dev/tty || { echo "install.sh: sudo did not accept the password; nothing was installed. Run it again with a user that has sudo." >&2; exit 1; }
      else
        echo "install.sh: sudo asks for a password and there is no terminal. Run it with ssh -t (ssh -t user@host 'sh install.sh ...'), or give this user sudo without a password (NOPASSWD in /etc/sudoers.d). Nothing was installed." >&2
        exit 1
      fi
    fi
  fi

  # next to this script only when it is a file that is this script (never under a pipe, where $0 is `sh` and the folder is
  # wherever the person happens to be)
  here=""
  if [ -f "$0" ] && grep -q 'halo-install-script-marker-7f3a' "$0" 2>/dev/null; then
    here="$(cd "$(dirname "$0")" && pwd)"
  fi
  # one command from nothing: no archive given and none next to this script, so the release the channel points to
  # (kanalen.json of fromorbit/halo-releases; the repository of the code is private and `latest` skips pre-releases)
  via_channel=0
  if [ -z "$from" ] && [ -z "$release" ]; then
    if [ -n "$here" ] && { { [ -x "$here/halo" ] && [ -d "$here/ui" ]; } || ls "$here"/halo-*-linux-x64.tar.gz >/dev/null 2>&1; }; then :; else
      if [ -n "${HALO_RELEASE_URL:-}" ]; then
        release="${HALO_RELEASE_URL%/}"
      else
        via_channel=1
        kanalen="${kanalen:-${HALO_KANALEN_URL:-https://raw.githubusercontent.com/fromorbit/halo-releases/main/kanalen.json}}"
      fi
    fi
  fi

  # only https (and file://, which is this computer); http only to loopback and only when asked, for a test
  badurl() { echo "install.sh: only https addresses are used (got $1). For a test on this computer: --insecure-http with an http://127.0.0.1 address." >&2; exit 2; }
  checkurl() { # <url> <release|from>
    case "$1" in
      https://*) ;;
      file://*) ;; # a folder or archive on this computer
      http://127.0.0.1|http://127.0.0.1[:/]*|http://localhost|http://localhost[:/]*) [ "$insecure" = 1 ] || badurl "$1" ;;
      http://*|ftp://*) badurl "$1" ;;
    esac
  }
  [ -z "$release" ] || checkurl "$release" release
  [ "$via_channel" = 0 ] || checkurl "$kanalen" kanalen
  case "$from" in *://*) checkurl "$from" from ;; esac
  protos='=https'
  [ "$insecure" = 0 ] || protos='=https,http'
  case "$from$release$kanalen${HALO_RELEASES_BASE:-}" in file://*) protos='=https,file' ;; esac
  fetch() { curl -fsSL --proto "$protos" --proto-redir '=https' --tlsv1.2 "$@"; }

  for tool in tar gzip sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { echo "install.sh: $tool is missing (Ubuntu: sudo apt install coreutils tar gzip)" >&2; exit 1; }
  done
  case "$from$release$kanalen" in
    *://*) command -v curl >/dev/null 2>&1 || { echo "install.sh: curl is needed for an address (Ubuntu: sudo apt install curl)" >&2; exit 1; } ;;
  esac

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  sumcheck() { # <archive file> <sums file>
    name="$(basename "$1")"
    want="$(grep "  $name\$" "$2" | cut -d' ' -f1 || true)"
    [ -n "$want" ] || { echo "install.sh: $name is not listed in SHA256SUMS" >&2; exit 1; }
    got="$(sha256sum "$1" | cut -d' ' -f1)"
    [ "$want" = "$got" ] || { echo "install.sh: checksum of $name does not match (wanted $want, got $got)" >&2; exit 1; }
    echo "checksum ok: $name"
  }
  # the newest archive of the names on stdin, in semver order as `halo update` has it (2.0.0 above 2.0.0-rc.1, rc.10 above
  # rc.9, +build ignored); `sort -V` gets the first wrong (T-196, #125 L8)
  newest_archive() {
    LC_ALL=C awk '{
      v = $0; sub(/^halo-/, "", v); sub(/-linux-x64\.tar\.gz$/, "", v); sub(/\+.*/, "", v)
      core = v; pre = ""
      if ((i = index(v, "-")) > 0) { core = substr(v, 1, i - 1); pre = substr(v, i + 1) }
      split(core, c, "."); k = ""
      for (j = 1; j <= 3; j++) k = k sprintf("%010d.", c[j] + 0)
      if (pre == "") k = k "~"
      else { m = split(pre, p, "."); for (j = 1; j <= m; j++) k = k (p[j] ~ /^[0-9]+$/ ? sprintf("0%010d", p[j] + 0) : "1" p[j]) "." }
      print k "\t" $0
    }' | LC_ALL=C sort | tail -n 1 | cut -f2-
  }

  nosums() { # <where>
    [ "$no_verify" = 1 ] && { echo "install.sh: no SHA256SUMS next to $1; installing without a checksum (--no-verify)" >&2; return 0; }
    echo "install.sh: no SHA256SUMS next to $1. A checksum is required; put the SHA256SUMS of the release next to it, or add --no-verify if you vouch for the archive." >&2
    exit 1
  }

  # the channel: which version it points to (a small JSON file; no jq needed), and then that version's own release folder
  if [ "$via_channel" = 1 ]; then
    fetch "$kanalen" -o "$work/kanalen.json" || { echo "install.sh: could not fetch $kanalen. Check the connection, or give a release folder: --release <https url>" >&2; exit 1; }
    flat="$(tr -d '\n\r' < "$work/kanalen.json")"
    printf '%s\n' "$flat" | grep -Eq '^[[:space:]]*\{[[:space:]]*"schema"[[:space:]]*:[[:space:]]*1[[:space:]]*,[[:space:]]*"stable"[[:space:]]*:[[:space:]]*(null|"[^"]*")[[:space:]]*,[[:space:]]*"beta"[[:space:]]*:[[:space:]]*(null|"[^"]*")[[:space:]]*\}[[:space:]]*$' || { echo "install.sh: $kanalen is not a kanalen.json (schema 1)" >&2; exit 1; }
    jsonfield() { printf '%s' "$flat" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
    stable_v="$(jsonfield stable)"; beta_v="$(jsonfield beta)"
    for v in "$stable_v" "$beta_v"; do
      case "$v" in ""|[0-9]*.[0-9]*.[0-9]*) ;; *) echo "install.sh: $kanalen names a version that is none: $v" >&2; exit 1 ;; esac
      case "$v" in *[!0-9A-Za-z.+-]*) echo "install.sh: $kanalen names a version that is none: $v" >&2; exit 1 ;; esac
    done
    picked=""
    if [ "$channel" = beta ]; then
      picked="$( { [ -z "$stable_v" ] || echo "halo-$stable_v-linux-x64.tar.gz"; [ -z "$beta_v" ] || echo "halo-$beta_v-linux-x64.tar.gz"; } | newest_archive | sed 's/^halo-//; s/-linux-x64\.tar\.gz$//')"
    elif [ -n "$stable_v" ]; then picked="$stable_v"
    elif [ "$channel_named" = 0 ] && [ -n "$beta_v" ]; then
      picked="$beta_v"; channel=beta
      echo "Note: there is no stable version yet; the newest test version ($beta_v) is installed. Choose with --channel stable|beta."
    fi
    [ -n "$picked" ] || { echo "install.sh: there is no version on the channel $channel yet (kanalen.json). Try --channel beta, or give --release <https url>." >&2; exit 1; }
    release="${HALO_RELEASES_BASE:-https://github.com/fromorbit/halo-releases/releases/download}/v$picked"
    checkurl "$release" release
    echo "Channel $channel: Halo $picked"
  fi

  if [ -n "$release" ]; then
    fetch "$release/SHA256SUMS" -o "$work/SHA256SUMS" || { echo "install.sh: no SHA256SUMS in $release" >&2; exit 1; }
    name="$(grep -oE 'halo-[0-9A-Za-z.+-]+-linux-x64\.tar\.gz' "$work/SHA256SUMS" | newest_archive || true)"
    [ -n "$name" ] || { echo "install.sh: $release/SHA256SUMS names no Linux archive" >&2; exit 1; }
    fetch "$release/$name" -o "$work/$name"
    sumcheck "$work/$name" "$work/SHA256SUMS"
    from="$work/$name"
  elif [ -z "$from" ]; then
    if [ -x "$here/halo" ] && [ -d "$here/ui" ]; then from="$here"; else
      from="$(ls "$here"/halo-*-linux-x64.tar.gz 2>/dev/null | tail -n 1 || true)"
      [ -n "$from" ] || { echo "install.sh: no archive next to this script; use --from <archive|folder|url>" >&2; exit 1; }
    fi
  fi

  case "$from" in
    *://*)
      archive="$work/$(basename "$from")"
      fetch "$from" -o "$archive"
      if fetch "$(dirname "$from")/SHA256SUMS" -o "$work/SHA256SUMS" 2>/dev/null; then sumcheck "$archive" "$work/SHA256SUMS"
      else nosums "the archive at $from"; fi
      ;;
    *)
      if [ -n "$release" ]; then archive="$from"
      elif [ -d "$from" ]; then archive=""; src="$from"
      else
        archive="$from"
        [ -f "$archive" ] || { echo "install.sh: $archive does not exist" >&2; exit 1; }
        if [ -f "$(dirname "$archive")/SHA256SUMS" ]; then sumcheck "$archive" "$(dirname "$archive")/SHA256SUMS"
        else nosums "$archive"; fi
      fi
      ;;
  esac

  if [ -n "${archive:-}" ]; then
    tar -xzf "$archive" -C "$work"
    src="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'halo-*' | head -n 1)"
  fi
  [ -x "$src/halo" ] && [ -d "$src/ui" ] || { echo "install.sh: $src has no halo program and ui folder" >&2; exit 1; }

  mkdir -p "$prefix/bin" "$prefix/share/halo"
  # replace in one step: a halo that is running keeps its old file
  cp "$src/halo" "$prefix/bin/halo.new" && chmod 755 "$prefix/bin/halo.new" && mv -f "$prefix/bin/halo.new" "$prefix/bin/halo"
  rm -rf "$prefix/share/halo/ui"
  cp -r "$src/ui" "$prefix/share/halo/ui"
  rm -rf "$prefix/share/halo/docker"
  if [ -d "$src/docker" ]; then cp -r "$src/docker" "$prefix/share/halo/docker"; fi
  # only an https address is remembered as the source of `halo update`
  # (a channel is remembered by its name, so `halo update` follows it to newer versions instead of staying on this folder)
  if [ "$via_channel" = 1 ]; then echo "$channel" > "$prefix/share/halo/channel"
  else case "$release" in https://*) echo "$release" > "$prefix/share/halo/release-url" ;; esac; fi

  halo="$prefix/bin/halo"
  echo "Installed: $("$halo" --version) in $halo"
  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "Note: $prefix/bin is not in your PATH yet. Ubuntu adds ~/.local/bin at the next login (open a new terminal); elsewhere add to your shell profile:  export PATH=\"$prefix/bin:\$PATH\"" ;;
  esac
  [ "$binary_only" = 0 ] || return 0

  if [ "$full" = 0 ]; then
    # no terminal and no choice: the old way, said aloud (a server wants --mode server --host <domain>)
    if [ "$init" = 1 ] && [ ! -f "$data/install.json" ]; then
      echo "Note: no --mode and no terminal to ask on: mode local (this computer only). Choose again with: halo init --mode network|server --force"
      "$halo" init --mode local
    fi
    echo "Next: halo serve (or open the Halo app, which starts it). For the engine, images and a service: halo doctor --fix"
    return 0
  fi

  # 1. the mode, once and right the first time; an installation that exists is never overwritten from here. Never a question.
  if [ -n "$have_mode" ]; then
    if [ -z "$mode" ] || { [ "$mode" = "$have_mode" ] && { [ -z "$host" ] || [ "$host" = "$have_host" ]; }; }; then
      echo "An installation exists in $data (mode $have_mode); it stays as it is.${public_url:+ (--public-url is not applied to it: halo init --mode $have_mode --public-url $public_url --force)}"
    else
      echo "Note: an installation exists in $data (mode $have_mode, $have_host) and it stays. To change it (your settings are kept): halo init --mode $mode${host:+ --host $host}${public_url:+ --public-url $public_url} --force" >&2
    fi
    init=0
  elif [ -z "$mode" ] && [ "$init" = 1 ]; then
    mode=local
    echo "Mode: local (this computer only). For a team server: --mode server --host <domain>"
  fi
  if [ "$init" = 1 ] && [ -n "$mode" ]; then
    say "Choosing the mode: $mode${host:+ ($host)}, engine $engine"
    set -- init --mode "$mode" --engine "$engine"
    [ -z "$host" ] || set -- "$@" --host "$host"
    [ -z "$public_url" ] || set -- "$@" --public-url "$public_url"
    "$halo" "$@"
  fi

  # 2. the engine, runtime images, linger and the service: halo doctor says what it will do before it uses root
  if [ "$no_engine" = 0 ]; then
    say "Checking the computer: engine (Podman), runtime images, service"
    set -- doctor --fix
    [ "$yes" = 0 ] || set -- "$@" --yes
    fail=0
    if [ "$tty" = 1 ]; then "$halo" "$@" < /dev/tty || fail=1; else "$halo" "$@" || fail=1; fi
    if [ "$fail" = 1 ]; then
      echo "install.sh: something is not in order yet. Read the lines above (each says the command that fixes it), then run: halo doctor --fix" >&2
      exit 1
    fi
    if [ "$images" = all ]; then say "Building the PHP images too (this takes a while)"; "$halo" images build all; fi
  elif [ "$no_service" = 0 ]; then
    say "Installing the service"
    "$halo" service install
  fi

  # 3. wait until Halo answers
  say "Waiting for Halo to start"
  n=0
  until "$halo" health >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "$n" -gt 60 ]; then echo "install.sh: Halo does not answer. See: halo service status, journalctl -u halo (or --user -u halo)" >&2; exit 1; fi
    sleep 1
  done

  # 4. the owner, when there are accounts (a Halo that has its owner already has no setup-code any more)
  accounts="$(grep -o '"accounts": *"[a-z]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  owner_done=""
  if [ "$accounts" = on ]; then
    if [ ! -f "$data/setup-code" ]; then
      owner_done="the owner exists already"
    elif [ -n "$owner" ] && [ -n "${HALO_OWNER_PASSWORD:-}" ]; then
      say "Making the owner $owner"
      printf '%s\n' "$HALO_OWNER_PASSWORD" | "$halo" setup --name "$owner" --password-stdin
      unset HALO_OWNER_PASSWORD
      owner_done="$owner"
    elif [ -n "$owner" ] && [ "$tty" = 1 ]; then
      say "Making the owner $owner: choose a password (at least 10 characters)"
      "$halo" setup --name "$owner" < /dev/tty
      owner_done="$owner"
    elif [ "$tty" = 1 ] && [ "$yes" = 0 ]; then
      say "Making the owner (the first account): choose a name and a password"
      "$halo" setup < /dev/tty
      owner_done="the owner"
    fi
  fi

  # 5. the last lines: where to open Halo and what to do first
  install_mode="$(grep -o '"mode": *"[a-z]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  install_host="$(grep -o '"host": *"[^"]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  case "$install_mode" in
    local|"")
      echo "Halo is running (this computer only)."
      echo "Open Halo:        http://127.0.0.1:7788"
      echo "First workspace:  halo repo scan <folder with your app>"
      return 0 ;;
  esac
  public="$(grep -o '"publicUrl": *"[^"]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  url="http://${install_host}:7788"
  [ -z "$public" ] || url="$public"
  # a later ssh command does not read the profile that puts ~/.local/bin in the PATH: say the path that always works
  case ":$PATH:" in *":$prefix/bin:"*) h=halo ;; *) h="$halo" ;; esac
  echo "Halo is running ($install_mode, accounts on)."
  echo "Open Halo:        $url"
  echo "In the Halo app:  Host toevoegen (add host) > $url"
  if [ -n "$public" ] && [ "${public#https://}" != "$public" ]; then
    # behind a reverse proxy: Halo listens on this computer only, the proxy is the front door (80 and 443, nothing else)
    spaces="$(printf '%s' "$public" | sed 's#^\([a-z]*://\)#\1<space>.#')"
    echo "Spaces open at:   $spaces   (Halo itself listens on 127.0.0.1; open only ports 80 and 443: sudo ufw allow 80/tcp; sudo ufw allow 443/tcp)"
    mkdir -p "$data/caddy"
    if "$halo" caddyfile --out "$data/caddy/Caddyfile"; then
      echo "Caddy:            the configuration is in $data/caddy/Caddyfile (the three steps are above)"
    else
      echo "Caddy:            the configuration could not be made; see: halo caddyfile --help" >&2
    fi
  else
    echo "Spaces open at:   http://<space>.${install_host}:7790   (open ports 7788 and 7790: sudo ufw allow 7788/tcp; sudo ufw allow 7790/tcp)"
  fi
  if [ -n "$owner_done" ] && [ -n "$owner" ] && [ "$owner_done" = "$owner" ]; then
    echo "Owner:            $owner (log in with your password)"
  elif [ -n "$owner_done" ]; then
    echo "Owner:            $owner_done"
  else
    echo "Owner:            not made yet: $h setup --name <name>"
  fi
  echo "Add someone:      $h users create anna --role member --password -   (password on standard input; --role admin for an admin)"
  case "$public" in
    https://*) ;;
    *) echo "Note: without TLS passwords travel unencrypted over the network; put a reverse proxy with TLS in front (docs: server.md)." ;;
  esac
}

main "$@"
