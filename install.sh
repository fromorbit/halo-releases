#!/bin/sh
# Installs halo (Linux x64, or macOS on Apple Silicon or Intel) for the current user and gets it running: the program, a
# container engine (Podman, with an instance of Halo's own), the runtime images, the mode, a service (systemd; a LaunchAgent
# on macOS) and, with accounts, the owner.
#
#   curl -fsSL https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh | sh    # on a terminal: a short guided setup
#                                                                    # (the mode, network by default; again: keep or switch)
#   curl -fsSL https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh | sh -s -- --mode server --host 192-168-1-50.sslip.io --owner mike
#   HALO_OWNER_PASSWORD=... sh install.sh --mode server --host halo.example.com --owner mike --yes   # no questions
#
# `sh install.sh --help` lists the options. The script only defines functions until its last line, which runs main, so a
# download that breaks halfway runs nothing. (halo-install-script-marker-7f3a)
set -eu

usage() {
  cat <<'EOF'
install.sh: installs halo and gets it running.

  curl -fsSL https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh | sh
  curl -fsSL https://raw.githubusercontent.com/fromorbit/halo-releases/main/install.sh | sh -s -- --mode server --host <domain> --owner <name>

  --mode local|network|server   how Halo runs. On a terminal without --mode, --host, --public-url, --owner and --yes a guided
                                setup asks it (Enter takes the default: network, this computer and others on the network,
                                with accounts; then the address and the owner). An existing installation is shown with its
                                mode, to keep (Enter) or to switch. Otherwise the default is local, said aloud; an existing
                                installation keeps its mode.
                                A team: --mode server --host <domain> (or --public-url https://<domain> behind Caddy)
  --host <domain>               base domain of the addresses of spaces (server: required). No domain of your own:
                                <ip-with-dashes>.sslip.io, for example 192-168-1-50.sslip.io (wildcard DNS to that IP)
  --public-url <url>            the address people use behind a reverse proxy (Caddy), for example https://halo.example.com: Halo then
                                listens on this computer only, and the Caddy configuration is made for you (halo caddyfile).
                                Replaces --host (the host is the name of the address)
  --yes                         do not ask the one "Continue?": every command that runs as root is still shown first, and only
                                those run (sudo and the owner's password are still asked on a terminal)
  --engine podman|docker|auto   container engine (default auto: Podman if it is there, else a running Docker, else Podman is installed)
  --with-engine                 install the engine and what rootless needs (the default of a full install)
  --no-engine                   leave the engine, images and doctor out
  --images core|all             runtime images to build (default core: node 20 and 22; all adds PHP, which is big)
  --owner <name>                with accounts: make the owner (password from HALO_OWNER_PASSWORD; on a terminal (ssh -t) it is asked
                                when that is not set; without a terminal and without it the script stops before it does anything)
  --no-service                  no systemd service (a user unit for local, a system unit for network and server; on macOS
                                no LaunchAgent)
  --release <url>               an https (or file://) release folder: its SHA256SUMS names the archive of this computer
                                (linux-x64, darwin-arm64 or darwin-x64), which must match
                                (default $HALO_RELEASE_URL, else the version the channel points to)
  --channel stable|beta         which channel to follow (default stable; while there is no stable version the newest test version,
                                said aloud). beta: the newest of stable and beta. Halo remembers it for `halo update`. The channels
                                are named in channels.json of fromorbit/halo-releases ($HALO_CHANNELS_URL, or --channels <https|file url>)
  --from <archive|folder|url>   an archive (.tar.gz), an unpacked folder or an https address; a SHA256SUMS next to an
                                archive or address is required unless --no-verify
  --no-verify                   install an archive without a SHA256SUMS (you vouch for it)
  --insecure-http               allow http to this computer (127.0.0.1) for a test; never remembered
  --allow-root                  run as root (a normal user with sudo is the way)
  --prefix <dir>                default ~/.local
  --no-init                     leave `halo init` out
  --binary-only                 only the program and the UI (what `halo update` uses)
  --uninstall                   removes what an install put there, the units too (not ~/.halo, your data); the root commands for a
                                system unit are shown first and, on a terminal without --yes, asked. `halo uninstall` asks first

A full install happens when there is a terminal, or --yes, --mode or --with-engine is given; otherwise only the program and
the UI are installed and `halo init --mode local` is run once. Without a terminal nothing is asked: what is missing stops the
script at once with the line that fixes it (exit 2), and sudo that needs a password stops it too (exit 1: use ssh -t, or sudo
without a password for this user). Every command that runs as root (packages, linger, subuids, the system unit) is
shown before it runs, from `halo doctor --root-plan`, and only those run. With accounts the guided setup ends with one
question: link this Halo to Orbit (fromorbit.dev, `halo orbit pair`)? Each step is one line; what its commands print goes to ~/.halo/install.log (in
$HALO_DATA_DIR when that is set), and a step that fails shows the last lines of it. Only a terminal gets the logo, colour
(not with NO_COLOR) and a little motion (HALO_NO_ANIM=1 keeps it all still; never in CI, which gets the plain title).
The checksum protects against a damaged download, not against a hostile source: trust is in https and in the
release folder. Needs tar, gzip, sha256sum, curl, and sudo for the engine.

macOS (Apple Silicon or Intel): Halo is for this computer (mode local) or the local network (mode network, the default of
the guided setup; without a terminal local); a team server runs on Linux, so --mode server, --host, --public-url and --owner stop at once. Nothing
runs with sudo: halo doctor --fix installs the engine with Homebrew (it names the commands and asks first; --yes passes
on) and the service is a LaunchAgent (~/Library/LaunchAgents/com.fromorbit.halo.plist). The checksum is shasum -a 256.
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
  engine_named=0
  switch_from=""
  orbit_row=""
  tty_eof=0
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
  channels=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:?--from needs a value}"; shift 2 ;;
      --release) release="${2:?--release needs a value}"; release="${release%/}"; shift 2 ;;
      --channel) channel="${2:?--channel needs a value}"; channel_named=1; shift 2 ;;
      --channels) channels="${2:?--channels needs a value}"; shift 2 ;;
      --kanalen) channels="${2:?--kanalen needs a value}"; shift 2 ;; # the old name of --channels, kept for older commands (V-694)
      --prefix) prefix="${2:?--prefix needs a value}"; shift 2 ;;
      --mode) mode="${2:?--mode needs a value}"; shift 2 ;;
      --host) host="${2:?--host needs a value}"; shift 2 ;;
      --public-url) public_url="${2:?--public-url needs a value}"; shift 2 ;;
      --engine) engine="${2:?--engine needs a value}"; engine_named=1; shift 2 ;;
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

  # --- how it looks: one line per step; a terminal gets a turning mark, colour (not with NO_COLOR) and the last line of
  # what the step runs; elsewhere the line waits for its end. What the commands print goes to the log, never to the screen.
  fancy=0
  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then fancy=1; fi
  B="" D="" G="" R="" Y="" N="" V="" M="" S="" depth=0
  if [ "$fancy" = 1 ] && [ -z "${NO_COLOR:-}" ]; then
    esc="$(printf '\033')"
    B="$esc[1m" D="$esc[2m" G="$esc[32m" R="$esc[31m" Y="$esc[33m" N="$esc[0m"
    # the colours of Halo (violet, mint, slate) as deep as the terminal goes: 24-bit, 256 or the basic sixteen
    depth=16
    case "${COLORTERM:-}" in truecolor|24bit) depth=24 ;; esac
    case "$depth-${TERM:-}" in 16-*256color*) depth=256 ;; esac
    if [ "$depth" = 16 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ] 2>/dev/null; then depth=256; fi
    case "$depth" in
      24) V="$esc[38;2;81;64;242m" M="$esc[38;2;47;211;166m" S="$esc[38;2;138;145;176m" ;;
      256) V="$esc[38;5;63m" M="$esc[38;5;43m" S="$esc[38;5;103m" ;;
      *) V="$esc[35m" M="$esc[36m" S="$D" ;;
    esac
    [ "$depth" = 16 ] || G="$M"
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) m_ok='✓' m_no='✗' m_skip='–' bar='│' dot='·' utf=1 ;;
    *) m_ok='+' m_no='x' m_skip='-' bar='|' dot='-' utf=0 ;;
  esac
  cols=80 wide=80
  if [ "$fancy" = 1 ]; then
    c="$( (stty size < /dev/tty) 2>/dev/null | awk '{print $2}')" || c=""
    case "$c" in ''|*[!0-9]*) ;; *) [ "$c" -lt 40 ] || cols="$c"; [ "$c" = 0 ] || wide="$c" ;; esac
  fi
  # the logo, and motion: only on a terminal and not in CI. HALO_NO_ANIM=1 keeps everything still (the seconds still
  # count), and so does a sleep that cannot wait a fraction of a second (some busybox).
  logo=0 anim=0 turn=1
  case "${HALO_NO_ANIM:-}" in ''|0) ;; *) turn=0 ;; esac
  [ -z "${CI:-}" ] || turn=0
  if [ "$fancy" = 1 ] && [ -z "${CI:-}" ]; then
    logo=1
    if [ "$turn" = 1 ] && sleep 0.01 2>/dev/null; then anim=1; fi
  fi
  say() { printf '%s\n' "$*"; }
  log="" log_keep=0 work="" spinner="" step_n=0 steps=0 step_open=0 step_quiet=0 step_t0=0 step_title="" step_from=0 label="" titled=0 keep_sudo=0 stopped=0
  ver="" hid=0 trapped=0 dl_hdr="" spin_dl=""
  secs() { if [ "$1" -ge 60 ]; then printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); else printf '%ds' "$1"; fi; }
  # the cursor is hidden only while something moves; every way out (the end, die, Ctrl-C, TERM, HUP, a no) shows it again
  cursor_off() { [ "$fancy" = 0 ] || { printf '\033[?25l'; hid=1; }; }
  cursor_on() { [ "$hid" = 0 ] || { hid=0; printf '\033[?25h' 2>/dev/null || :; }; }
  frame() { # <n>: the turning mark, a satellite going round its orbit (still with HALO_NO_ANIM=1 and in CI)
    [ "$turn" = 1 ] || set -- 0
    if [ "$utf" = 1 ]; then
      case $(($1 % 8)) in 0) f='⠉' ;; 1) f='⠘' ;; 2) f='⠰' ;; 3) f='⢠' ;; 4) f='⣀' ;; 5) f='⡄' ;; 6) f='⠆' ;; *) f='⠃' ;; esac
    else
      case $(($1 % 4)) in 0) f='|' ;; 1) f='/' ;; 2) f='-' ;; *) f='\' ;; esac
    fi
  }
  # The logo: the orbit of Halo's icon (three arcs round the centre, three satellites, one of them mint) and the word with
  # the mint dot in its o, under it what this is. awk draws it from one picture of one byte per cell, so every awk counts
  # the same, as frame <f> of 0 to 11: the mint satellite goes once round the orbit while the letters come up; 11 is the
  # logo at rest. <up> lines are drawn over (the frame before).
  logo_frame() { # <f> <up>
    LC_ALL=C awk -v f="$1" -v up="$2" -v k="$anim" -v u="$utf" -v depth="$depth" -v title="installer${ver:+ $dot $ver}" '
      function cube(v) { return v < 48 ? 0 : v < 115 ? 1 : int((v - 35) / 40) }
      function hue(t,   r, g, b) { # violet (t = 0) to mint (t = 1)
        if (depth == 0) return ""
        r = int(81 - 34 * t + 0.5); g = int(64 + 147 * t + 0.5); b = int(242 - 76 * t + 0.5)
        if (depth == 24) return ";38;2;" r ";" g ";" b
        if (depth == 256) return ";38;5;" (16 + 36 * cube(r) + 6 * cube(g) + cube(b))
        return t < 0.34 ? ";35" : (t < 0.67 ? ";94" : ";36")
      }
      function paint(ch, sgr) { return depth == 0 || sgr == "" ? ch : "\033[" substr(sgr, 2) "m" ch "\033[0m" }
      BEGIN {
        # a ╭  b ╮  c ╰  d ╯  - ─  | │  v ╷  ^ ╵  < ╴  > ╶  T ├  E ┤  7 ┐  L ╱  R ╲  o a satellite  m the mint one
        # O the centre  D the mint dot of the o
        split("  a---<    / L       m /o    O    v/ R       L /  c-< o d  ", o, "/")
        split("v           v       /|           |       /T---b a---7 |  a---b/|   | |   | |  | D |/^   ^ c---E c< c---d", w, "/")
        n = split("a b c d - | v ^ < > T E 7 L R o m O D", K, " ")
        if (u) split("╭ ╮ ╰ ╯ ─ │ ╷ ╵ ╴ ╶ ├ ┤ ┐ ╱ ╲ • • ● ● ·", G, " ")
        else split(". . \047 \047 - | | | - - | | . / \\ o o O o .", G, " ")
        for (i = 1; i <= n; i++) glyph[K[i]] = G[i]
        trail = G[n + 1]
        mint = depth == 24 ? ";38;2;47;211;166" : (depth == 256 ? ";38;5;43" : (depth == 16 ? ";36" : ""))
        slate = depth == 24 ? ";38;2;138;145;176" : (depth == 256 ? ";38;5;103" : (depth == 16 ? ";2" : ""))
        # the mint satellite in frames 0 to 8 (row, column): once round, clockwise, home in frame 9
        split("2 4 4 4 3 1 0 0 0", pr, " "); split("10 8 5 3 1 1 4 6 8", pc, " ")
        ow = length(o[1]); W = ow + 3 + length(w[1])
        if (up > 0) printf "\033[%dA", up
        for (r = 0; r < 6; r++) {
          line = r < 5 ? o[r + 1] "   " w[r + 1] : ""
          out = "  "; gap = ""
          for (x = 0; x < W; x++) {
            ch = substr(line, x + 1, 1); s = ""
            if (ch == "") ch = " "
            if (x < ow) { # the orbit, faint in the first two frames, and the mint satellite on its way round it
              if (ch == "m") { if (f < 9) ch = " "; else s = ";1" mint }
              else if (ch == "o") { if (f < 1) ch = " "; else s = ";1" }
              else if (ch == "O") s = f < 2 ? ";2" : ";1"
              else if (ch != " ") s = (f < 2 ? ";2" : "") hue(x / (W - 1))
              if (f < 9 && r == pr[f + 1] + 0 && x == pc[f + 1] + 0) { ch = "m"; s = ";1" mint }
              else if (f >= 1 && f < 10 && r == pr[f] + 0 && x == pc[f] + 0) { s = mint; if (ch == " ") { ch = "."; s = ";2" mint } }
            } else if (ch == "D") { if (f < 10) ch = " "; else s = ";1" mint }
            else if (ch != " ") { # the word: a letter every other frame, faint first
              l = x - ow - 3; l = l < 5 ? 0 : (l < 11 ? 1 : (l < 14 ? 2 : 3))
              if (f < 2 + 2 * l) ch = " "; else s = (f == 2 + 2 * l ? ";2" : ";1") hue(x / (W - 1))
            }
            if (ch == " ") { gap = gap " "; continue }
            out = out gap paint(ch == "." ? trail : glyph[ch], s); gap = ""
          }
          if (r == 5 && f >= 10) out = out sprintf("%" (ow + 3) "s", "") paint(title, f == 10 ? ";2" : slate)
          printf "%s%s\n", out, k ? "\033[K" : ""
        }
      }'
  }
  title() { # the first lines: on a terminal (not in CI) the logo, else the name; on a narrow terminal the logo in one line
    titled=1
    if [ "$logo" = 0 ]; then printf '%sHalo installer%s\n' "$B" "$N"; return 0; fi
    if [ "$wide" -lt 60 ]; then
      mk='◉'; [ "$utf" = 1 ] || mk='(o)'
      printf '  %s%s%s %shal%s%s%so%s  %s%s%s\n' "$V" "$mk" "$N" "$B" "$N" "$B" "$M" "$N" "$S" "installer${ver:+ $dot $ver}" "$N"
      return 0
    fi
    # the logo is only a look: an awk that cannot draw it never stops the install
    [ "$anim" = 1 ] || { logo_frame 11 0 || :; return 0; }
    # the frames draw over each other; before the traps of the steps exist, Ctrl-C now still gives the cursor back
    cursor_off
    [ "$trapped" = 1 ] || { trap 'cursor_on; exit 130' INT; trap 'cursor_on; exit 143' TERM; trap 'cursor_on; exit 129' HUP; }
    lf=0 up=0
    while [ "$lf" -le 11 ]; do
      logo_frame "$lf" "$up" || :
      [ "$lf" = 11 ] || sleep 0.05 || :
      lf=$((lf + 1)) up=6
    done
    [ "$trapped" = 1 ] || trap - INT TERM HUP
    cursor_on
  }
  step() { # <title>: the next numbered step begins
    step_n=$((step_n + 1)); step_open=1; step_quiet=0; step_t0="$(date +%s)"; step_title="$1"
    label="${D}[$step_n/$steps]${N} ${B}$(printf '%-16s' "$1")${N}"
    printf '%s ' "$label"
    [ -z "$log" ] || { printf '\n== [%s/%s] %s\n' "$step_n" "$steps" "$1" >> "$log"; step_from="$(wc -l < "$log" | tr -d ' ')"; }
  }
  resume() { printf '%s ' "$label"; step_open=1; } # the step line again, after lines of its own (a question)
  break_line() { # an open step line ends (clean, without the turning mark) so lines of its own can follow
    [ "$step_open" = 1 ] || return 0
    [ "$fancy" = 0 ] || printf '\r\033[K%s' "$label"
    printf '\n'
    step_open=0
  }
  finish() { # <colour> <mark> <text>: the step ends
    [ "$fancy" = 0 ] || printf '\r\033[K%s ' "$label"
    printf '%s%s%s %s\n' "$1" "$2" "$N" "$3"
    step_open=0
  }
  ok() { finish "$G" "$m_ok" "$*"; }
  skip() { finish "$D" "$m_skip" "$*"; }
  note() { printf '      %s! %s%s\n' "$Y" "$*" "$N"; }
  took() { s=$(($(date +%s) - step_t0)); [ "$s" -lt 2 ] || printf ' (%s)' "$(secs "$s")"; }
  tail_of_log() { # the end of what this step ran (its part of the log), on standard error
    [ -n "$log" ] && [ -s "$log" ] || return 0
    printf '%sThe last lines of what it ran:%s\n' "$D" "$N" >&2
    tail -n "+$((step_from + 1))" "$log" | tail -n 20 | tr -d '\r' | sed "s/^/  $bar /" >&2
    [ "$log_keep" = 0 ] || printf 'The whole log: %s\n' "$log" >&2
  }
  die() { # <exit code> <message>: an open step ends with its mark of failure, the message goes to standard error
    code="$1"; shift
    spin_stop
    [ "$step_open" = 0 ] || finish "$R" "$m_no" "failed$(took)"
    printf '%s\n' "$*" >&2
    [ "$step_quiet" = 0 ] || tail_of_log
    step_quiet=0
    exit "$code"
  }
  # How much of a download is in, for the turning line: the size of the file so far, its speed, and when the server said
  # how big it is (Content-Length in the headers curl keeps of the same request; after a redirect the last response
  # counts) a bar and the percentage. Nothing is asked of the server for it.
  dl_progress() { # <bytes> <bytes a second, or nothing yet>
    hf="$dl_hdr"; [ -f "$hf" ] || hf=/dev/null
    LC_ALL=C awk -v have="$1" -v rate="$2" -v room="$((cols - 34))" -v u="$utf" -v on="$M" -v off="$N$D" '
      function mb(n) { return n >= 1048576 ? sprintf("%.1f MB", n / 1048576) : sprintf("%d kB", n / 1024) }
      tolower($1) ~ /^http\// { len = 0 }
      tolower($1) == "content-length:" { len = $2 + 0 }
      END {
        speed = rate != "" ? "  " mb(rate) "/s" : ""
        if (len <= 0 || have > len) { printf "%s%s", mb(have), speed; exit }
        p = int(100 * have / len); t = sprintf("%3d%%  %s / %s", p, mb(have), mb(len))
        # what goes first when the line is short: the speed, then the bar
        if (length(t speed) + 10 <= room || length(t) + 10 > room && length(t speed) <= room) t = t speed
        w = room - length(t) - 2; if (w > 24) w = 24
        if (w < 8) { printf "%s", t; exit }
        fill = int(w * have / len); a = ""; b = ""
        for (i = 0; i < w; i++) if (i < fill) a = a (u ? "━" : "#"); else b = b (u ? "─" : "-")
        printf "%s%s%s%s  %s", on, a, off, b, t
      }' "$hf" 2>/dev/null
  }
  spin_start() { # on a terminal: the step line turns, with the seconds and the last line of the log, until spin_stop
    [ "$fancy" = 1 ] || return 0
    room=$((cols - 44))
    cursor_off
    (
      i=0 was="" t1="" h1=0 rate=""
      while kill -0 "$$" 2>/dev/null; do
        frame "$i"
        now="$(date +%s)"
        last=""
        if [ -n "$spin_dl" ]; then
          have="$(wc -c 2>/dev/null < "$spin_dl" | tr -d ' ')" || have=""
          # the speed between two turns that each came just after the second changed, so it is at most a turn off
          if [ -n "$was" ] && [ "$now" != "$was" ]; then
            if [ -z "$t1" ]; then t1="$now" h1="${have:-0}"; else rate=$(((${have:-0} - h1) / (now - t1))); fi
          fi
          was="$now"
          last="$(dl_progress "${have:-0}" "$rate")" || last=""
        elif [ "$room" -gt 9 ] && [ -n "$log" ]; then
          last="$(tail -n 1 "$log" 2>/dev/null | tr '\r' '\n' | tail -n 1 | LC_ALL=C tr -cd '[:print:]' | cut -c "1-$room")" || last=""
        fi
        printf '\r\033[K%s %s%s%s %s%s  %s%s' "$label" "$M" "$f" "$N" "$D" "$(secs $((now - step_t0)))" "$last" "$N"
        # sudo was asked once, up front: a long step (image builds) keeps it valid, so it never asks over this line
        if [ "$keep_sudo" = 1 ] && [ $((i % 250)) = 249 ]; then sudo -n -v 2>/dev/null || true; fi
        i=$((i + 1))
        sleep 0.2 2>/dev/null || sleep 1
      done
    ) &
    spinner=$!
  }
  spin_stop() { [ -z "$spinner" ] || { kill "$spinner" 2>/dev/null || true; wait "$spinner" 2>/dev/null || true; spinner=""; }; cursor_on; }
  quiet() { # <command...>: runs it with its output in the log (never on the screen) and returns its exit code
    [ -z "$log" ] || printf '$ %s\n' "$*" >> "$log"
    step_quiet=1
    spin_start
    qrc=0
    "$@" >> "${log:-/dev/null}" 2>&1 < /dev/null || qrc=$?
    spin_stop
    return "$qrc"
  }
  ask() { # <question> <default>: one line from the terminal; Enter, or the end of the input, takes the default
    if [ -n "$2" ]; then printf '%s %s[%s]%s ' "$1" "$D" "$2" "$N" > /dev/tty; else printf '%s ' "$1" > /dev/tty; fi
    eof=0
    # after the end of the input (Ctrl-D) every later question takes its default too, without waiting for a second one
    if [ "$tty_eof" = 1 ] || ! IFS= read -r answer < /dev/tty; then eof=1 tty_eof=1; answer=""; printf '\n' > /dev/tty; fi
    answer="$(printf '%s' "$answer" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$answer" ] || answer="$2"
  }

  # a terminal to ask on, also when the script itself comes in over a pipe (curl | sh)
  if (exec < /dev/tty) 2>/dev/null; then tty=1; else tty=0; fi
  # a full install (engine, mode, service, owner) when someone is there to ask or said what they want; else the program only
  full=0
  if [ "$tty" = 1 ] || [ "$yes" = 1 ] || [ -n "$mode" ] || [ "$with_engine" = 1 ]; then full=1; fi
  [ "$binary_only" = 0 ] || full=0
  data="${HALO_DATA_DIR:-$HOME/.halo}"

  # The archive of this computer: Linux x64, or macOS on Apple Silicon or Intel (a shell under Rosetta on Apple Silicon says
  # x86_64 and still gets arm64). Anything else is refused below, after --uninstall, which works everywhere.
  os="" plat="" kind="" modes="local|network|server"
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-amd64) os=linux plat=linux-x64 kind="Linux archive" ;;
    Darwin-arm64) os=darwin plat=darwin-arm64 ;;
    Darwin-x86_64)
      os=darwin plat=darwin-x64
      [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" != 1 ] || plat=darwin-arm64 ;;
  esac
  [ "$os" != darwin ] || { kind="macOS archive ($plat)"; modes="local|network"; }

  unit="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/halo.service"
  agent="$HOME/Library/LaunchAgents/com.fromorbit.halo.plist"
  if [ "$uninstall" = 1 ] && [ "$os" = darwin ]; then
    # the LaunchAgent: stopped (it may not be loaded, which is fine) and its file removed; nothing needs root on a Mac
    had_agent=0
    [ ! -f "$agent" ] || had_agent=1
    launchctl bootout "gui/$(id -u)/com.fromorbit.halo" >/dev/null 2>&1 || true
    rm -f "$agent"
    [ "$had_agent" = 0 ] || echo "The LaunchAgent com.fromorbit.halo is stopped and removed ($agent)."
  elif [ "$uninstall" = 1 ]; then
    if [ -f "$unit" ]; then
      systemctl --user disable --now halo.service >/dev/null 2>&1 || true
      rm -f "$unit"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    if [ -f /etc/systemd/system/halo.service ]; then
      # every command that runs as root is shown first; on a terminal without --yes it is asked, no by default (halo uninstall asks too)
      printf 'The system unit /etc/systemd/system/halo.service needs root to remove. These commands run as root (sudo):\n'
      printf '  sudo systemctl disable --now halo.service\n  sudo rm -f /etc/systemd/system/halo.service\n  sudo systemctl daemon-reload\n'
      if [ "$tty" = 1 ] && [ "$yes" = 0 ] && ! consent N; then
        echo "install.sh: the system unit and the program stay: the root commands were not approved." >&2
        exit 1
      fi
      sudo systemctl disable --now halo.service || { echo "install.sh: could not stop the service; nothing was removed. Try: sudo systemctl disable --now halo.service" >&2; exit 1; }
      sudo rm -f /etc/systemd/system/halo.service && sudo systemctl daemon-reload || true
    fi
  fi
  if [ "$uninstall" = 1 ]; then
    rm -f "$prefix/bin/halo" "$prefix/bin/halo.prev"
    # only what an install and halo update put there: another program can keep files of its own in share/halo (the Halo
    # before 2.0 kept its database and keys there), and those stay, said aloud
    sh_dir="$prefix/share/halo"
    for f in ui ui.prev docker update-stage channel release-url install.json.prev update.json update.lock; do rm -rf "${sh_dir:?}/$f"; done
    if [ -d "$sh_dir" ] && ! rmdir "$sh_dir" 2>/dev/null; then
      echo "Left in $sh_dir: files that are not part of this program ($(ls -A "$sh_dir" | tr '\n' ' ' | sed 's/ $//'))."
    fi
    echo "halo removed from $prefix (your data in $data is untouched; halo uninstall --purge removes it too)."
    # a terminal gets a goodbye: the satellite leaves its orbit
    if [ "$logo" = 1 ]; then
      if [ "$utf" = 1 ]; then trace='·  ·  ·' sat='•'; else trace='.  .  .' sat='o'; fi
      printf '  %s%s%s %s%s%s  %shalo has left the orbit. See you again.%s\n' "$D" "$trace" "$N" "$B$M" "$sat" "$N" "$S" "$N"
    fi
    return 0
  fi

  if [ "$(id -u)" = 0 ] && [ "$allow_root" = 0 ]; then
    echo "install.sh: this is for a normal user with sudo, not for root: Halo, its engine and its service run as that user. Log in as that user and run it again (--allow-root if you really mean root)." >&2
    exit 2
  fi
  if [ -z "$os" ]; then
    if [ "$(uname -s)" = Linux ]; then
      echo "install.sh: there is no Halo for Linux on $(uname -m) yet: it runs on Linux x64 (x86_64) and on macOS (Apple Silicon and Intel). Nothing was installed." >&2
    else
      echo "install.sh: this installer is for Linux x64 and macOS (this is $(uname -s) $(uname -m)). Windows: unpack the .zip." >&2
    fi
    exit 1
  fi
  # A team server runs on Linux: on a Mac Halo is for this computer or the local network, said before anything is fetched
  if [ "$os" = darwin ]; then
    bad=""
    [ "$mode" != server ] || bad="--mode server"
    for f in "--host:$host" "--public-url:$public_url" "--owner:$owner"; do
      [ -n "$bad" ] || [ -z "${f#*:}" ] || bad="${f%%:*}"
    done
    if [ -n "$bad" ]; then
      echo "install.sh: $bad is for a team server, and a team server runs on Linux. On a Mac: --mode local (this computer only, the default) or --mode network (the local network)." >&2
      exit 2
    fi
  fi

  # What an installation that exists says, read once (it is never overwritten from here).
  have_mode=""
  have_host=""
  if [ -f "$data/install.json" ]; then
    have_mode="$(grep -o '"mode": *"[a-z]*"' "$data/install.json" | cut -d'"' -f4 || true)"
    have_host="$(grep -o '"host": *"[^"]*"' "$data/install.json" | cut -d'"' -f4 || true)"
  fi

  # A person at a terminal who said nothing about the mode is asked it, network by default, and for an accounts mode the
  # address and the owner, each with a default, so Enter, Enter, Enter installs it (V-689, V-714). An installation that
  # exists is shown with its mode, to keep (Enter) or to switch. With any of those flags, or without a terminal, nothing is
  # asked (V-116). On a Mac a team server is not offered (V-690).
  if [ "$full" = 1 ] && [ "$tty" = 1 ] && [ "$init" = 1 ] && [ "$yes" = 0 ] && [ -z "$mode$host$public_url$owner" ]; then
    guided
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
    if [ "$os" = linux ] && [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1; then
      [ "$no_engine" = 1 ] || need_sudo=1
      { [ "$eff_mode" = local ] || [ "$no_service" = 1 ]; } || need_sudo=1
      # a switch away from a system unit removes it first
      [ -z "$switch_from" ] || [ ! -f /etc/systemd/system/halo.service ] || need_sudo=1
    fi
    if [ "$need_sudo" = 1 ] && ! sudo -n true 2>/dev/null; then
      if [ "$tty" = 1 ]; then
        say "Halo needs sudo for the engine and the service: sudo asks for your password, once."
        sudo -v < /dev/tty || { echo "install.sh: sudo did not accept the password; nothing was installed. Run it again with a user that has sudo." >&2; exit 1; }
        keep_sudo=1
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
  # (channels.json of fromorbit/halo-releases; the repository of the code is private and `latest` skips pre-releases)
  via_channel=0
  if [ -z "$from" ] && [ -z "$release" ]; then
    if [ -n "$here" ] && { { [ -x "$here/halo" ] && [ -d "$here/ui" ]; } || ls "$here"/halo-*-"$plat".tar.gz >/dev/null 2>&1; }; then :; else
      if [ -n "${HALO_RELEASE_URL:-}" ]; then
        release="${HALO_RELEASE_URL%/}"
      else
        via_channel=1
        # HALO_KANALEN_URL is the old name of HALO_CHANNELS_URL, still honoured (V-694)
        channels="${channels:-${HALO_CHANNELS_URL:-${HALO_KANALEN_URL:-https://raw.githubusercontent.com/fromorbit/halo-releases/main/channels.json}}}"
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
  [ "$via_channel" = 0 ] || checkurl "$channels" channels
  case "$from" in *://*) checkurl "$from" from ;; esac
  protos='=https'
  [ "$insecure" = 0 ] || protos='=https,http'
  case "$from$release$channels${HALO_RELEASES_BASE:-}" in file://*) protos='=https,file' ;; esac
  fetch() { # <url> <curl options...>; with dl_hdr set, the headers of the response go there too (how big a download is)
    if [ -n "$dl_hdr" ]; then curl -fsSL --proto "$protos" --proto-redir '=https' --tlsv1.2 -D "$dl_hdr" "$@"
    else curl -fsSL --proto "$protos" --proto-redir '=https' --tlsv1.2 "$@"; fi
  }

  # the checksum: sha256sum, else shasum -a 256 (macOS has only that)
  sha=sha256sum
  command -v sha256sum >/dev/null 2>&1 || ! command -v shasum >/dev/null 2>&1 || sha="shasum -a 256"
  for tool in tar gzip "${sha%% *}"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "install.sh: $tool is missing (Ubuntu: sudo apt install coreutils tar gzip)" >&2; exit 1; }
  done
  case "$from$release$channels" in
    *://*) command -v curl >/dev/null 2>&1 || { echo "install.sh: curl is needed for an address (Ubuntu: sudo apt install curl)" >&2; exit 1; } ;;
  esac

  work="$(mktemp -d)"
  # a command of a step that fails ends the script (set -e): the step gets its mark, a sentence and the end of the log
  trap 'rc=$?; spin_stop; cursor_on; if [ "$rc" != 0 ] && [ "$step_open" = 1 ]; then if [ "$stopped" = 1 ]; then finish "$R" "$m_no" "stopped"; else finish "$R" "$m_no" "failed$(took)"; echo "install.sh: the step $step_title failed (exit $rc)." >&2; [ "$step_quiet" = 0 ] || tail_of_log; fi; fi; rm -rf "$work"' EXIT
  trap 'stopped=1; exit 130' INT
  trap 'stopped=1; exit 143' TERM
  trap 'stopped=1; rm -rf "$work"; exit 129' HUP # ssh -t that drops: the temporary folder goes first (no terminal to print on)
  trapped=1
  # the log of this run: in the data folder (private, as Halo keeps it), or only for this run when that cannot be written
  log="$work/install.log"
  if [ "$binary_only" = 0 ] && (umask 077 && mkdir -p "$data" && : > "$data/install.log") 2>/dev/null; then
    log="$data/install.log"
    log_keep=1
  fi
  printf 'install.sh, %s\n' "$(date)" >> "$log"

  sumcheck() { # <archive file> <sums file>
    name="$(basename "$1")"
    want="$(grep "  $name\$" "$2" | cut -d' ' -f1 || true)"
    [ -n "$want" ] || die 1 "install.sh: $name is not listed in SHA256SUMS"
    got="$($sha "$1" | cut -d' ' -f1)"
    [ "$want" = "$got" ] || die 1 "install.sh: checksum of $name does not match (wanted $want, got $got)"
    said="checksum ok: $name"
  }
  # the newest archive of the names on stdin, in semver order as `halo update` has it (2.0.0 above 2.0.0-rc.1, rc.10 above
  # rc.9, +build ignored); `sort -V` gets the first wrong (T-196, #125 L8)
  newest_archive() {
    LC_ALL=C awk -v plat="$plat" '{
      v = $0; sub(/^halo-/, "", v); sub("-" plat "\\.tar\\.gz$", "", v); sub(/\+.*/, "", v)
      core = v; pre = ""
      if ((i = index(v, "-")) > 0) { core = substr(v, 1, i - 1); pre = substr(v, i + 1) }
      split(core, c, "."); k = ""
      for (j = 1; j <= 3; j++) k = k sprintf("%010d.", c[j] + 0)
      if (pre == "") k = k "~"
      else { m = split(pre, p, "."); for (j = 1; j <= m; j++) k = k (p[j] ~ /^[0-9]+$/ ? sprintf("0%010d", p[j] + 0) : "1" p[j]) "." }
      print k "\t" $0
    }' | LC_ALL=C sort | tail -n 1 | cut -f2-
  }
  version_of() { basename "$1" | sed -n "s/^halo-\(.*\)-$plat\.tar\.gz\$/\1/p"; }

  nosums() { # <where>
    if [ "$no_verify" = 1 ]; then
      echo "install.sh: no SHA256SUMS next to $1; installing without a checksum (--no-verify)" >&2
      said="no checksum (--no-verify)"
      return 0
    fi
    die 1 "install.sh: no SHA256SUMS next to $1. A checksum is required; put the SHA256SUMS of the release next to it, or add --no-verify if you vouch for the archive."
  }

  # --- where the program comes from, found before anything is installed (only the small files are fetched here)
  ver=""
  ver_from=""
  channel_note=""
  # the channel: which version it points to (a small JSON file; no jq needed), and then that version's own release folder
  if [ "$via_channel" = 1 ]; then
    # channels.json first. When that cannot be fetched or is no channels.json, the old name next to it, kanalen.json: a
    # release repository that has only the old file keeps working (V-694). The publisher writes both with the same bytes.
    channels_get() { # <url> <quiet 0|1>: 0 read into $flat, 1 not fetched, 2 not a channels.json of schema 1
      if [ "$2" = 1 ]; then fetch "$1" -o "$work/channels.json" 2>/dev/null || return 1
      else fetch "$1" -o "$work/channels.json" || return 1; fi
      flat="$(tr -d '\n\r' < "$work/channels.json")"
      printf '%s\n' "$flat" | grep -Eq '^[[:space:]]*\{[[:space:]]*"schema"[[:space:]]*:[[:space:]]*1[[:space:]]*,[[:space:]]*"stable"[[:space:]]*:[[:space:]]*(null|"[^"]*")[[:space:]]*,[[:space:]]*"beta"[[:space:]]*:[[:space:]]*(null|"[^"]*")[[:space:]]*\}[[:space:]]*$' || return 2
    }
    legacy=""
    case "$channels" in */channels.json) legacy="${channels%channels.json}kanalen.json" ;; esac
    ch_rc=0
    if [ -n "$legacy" ]; then channels_get "$channels" 1 || ch_rc=$?; else channels_get "$channels" 0 || ch_rc=$?; fi
    if [ "$ch_rc" != 0 ] && [ -n "$legacy" ]; then
      legacy_rc=0
      channels_get "$legacy" 1 || legacy_rc=$?
      [ "$legacy_rc" != 0 ] || { channels="$legacy"; ch_rc=0; }
    fi
    [ "$ch_rc" != 1 ] || die 1 "install.sh: could not fetch $channels. Check the connection, or give a release folder: --release <https url>"
    [ "$ch_rc" = 0 ] || die 1 "install.sh: $channels is not a channels.json (schema 1)"
    jsonfield() { printf '%s' "$flat" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }
    stable_v="$(jsonfield stable)"; beta_v="$(jsonfield beta)"
    for v in "$stable_v" "$beta_v"; do
      case "$v" in ""|[0-9]*.[0-9]*.[0-9]*) ;; *) die 1 "install.sh: $channels names a version that is none: $v" ;; esac
      case "$v" in *[!0-9A-Za-z.+-]*) die 1 "install.sh: $channels names a version that is none: $v" ;; esac
    done
    picked=""
    if [ "$channel" = beta ]; then
      picked="$( { [ -z "$stable_v" ] || echo "halo-$stable_v-$plat.tar.gz"; [ -z "$beta_v" ] || echo "halo-$beta_v-$plat.tar.gz"; } | newest_archive | sed "s/^halo-//; s/-$plat\.tar\.gz\$//")"
    elif [ -n "$stable_v" ]; then picked="$stable_v"
    elif [ "$channel_named" = 0 ] && [ -n "$beta_v" ]; then
      picked="$beta_v"; channel=beta
      channel_note="Note: there is no stable version yet; the newest test version ($beta_v) is installed. Choose with --channel stable|beta."
    fi
    [ -n "$picked" ] || die 1 "install.sh: there is no version on the channel $channel yet (channels.json). Try --channel beta, or give --release <https url>."
    release="${HALO_RELEASES_BASE:-https://github.com/fromorbit/halo-releases/releases/download}/v$picked"
    checkurl "$release" release
    ver="$picked"
    ver_from="channel $channel"
  fi

  archive=""
  src=""
  dl_url=""
  sums=""
  if [ -n "$release" ]; then
    fetch "$release/SHA256SUMS" -o "$work/SHA256SUMS" || die 1 "install.sh: no SHA256SUMS in $release"
    name="$(grep -oE "halo-[0-9A-Za-z.+-]+-$plat\.tar\.gz" "$work/SHA256SUMS" | newest_archive || true)"
    [ -n "$name" ] || die 1 "install.sh: $release/SHA256SUMS names no $kind"
    dl_url="$release/$name"
    archive="$work/$name"
    sums="$work/SHA256SUMS"
    [ -n "$ver" ] || { ver="$(version_of "$name")"; ver_from="$release"; }
  else
    if [ -z "$from" ]; then
      if [ -x "$here/halo" ] && [ -d "$here/ui" ]; then from="$here"; else
        from="$(ls "$here"/halo-*-"$plat".tar.gz 2>/dev/null | tail -n 1 || true)"
        [ -n "$from" ] || die 1 "install.sh: no archive next to this script; use --from <archive|folder|url>"
      fi
    fi
    case "$from" in
      *://*) dl_url="$from"; archive="$work/$(basename "$from")" ;;
      *)
        if [ -d "$from" ]; then src="$from"
        else
          archive="$from"
          [ -f "$archive" ] || die 1 "install.sh: $archive does not exist"
        fi
        ;;
    esac
    ver="$(version_of "$from")"
    ver_from="$from"
  fi

  # --- the steps, counted before the first one so each line says where it is
  steps=1
  [ -z "$archive" ] || steps=$((steps + 1))
  owner_step=0
  if [ "$binary_only" = 1 ]; then :
  elif [ "$full" = 0 ]; then
    if [ "$init" = 1 ] && [ ! -f "$data/install.json" ]; then steps=$((steps + 1)); fi
  else
    if [ -n "$have_mode" ] || [ "$init" = 1 ]; then steps=$((steps + 1)); fi
    if [ "$no_engine" = 0 ]; then
      steps=$((steps + 1))
      [ "$images" = core ] || steps=$((steps + 1))
    elif [ "$no_service" = 0 ]; then steps=$((steps + 1))
    fi
    steps=$((steps + 1))
    if [ "$eff_mode" != local ] && { [ -n "$owner" ] || { [ "$tty" = 1 ] && [ "$yes" = 0 ]; }; }; then
      owner_step=1
      steps=$((steps + 1))
    fi
  fi

  # the header: what is installed, for whom, and where the log is (not for `halo update` and the app, which say it themselves)
  if [ "$binary_only" = 0 ]; then
    if [ "$titled" = 0 ]; then title; [ "$logo" = 0 ] || printf '\n'; fi
    if [ -n "$ver" ]; then printf '  Version  %s (%s)\n' "$ver" "$ver_from"; else printf '  From     %s\n' "$ver_from"; fi
    if [ "$full" = 1 ]; then
      if [ -n "$have_mode" ]; then for_line="the installation in $data (mode $have_mode), which stays as it is"
      else
        case "$eff_mode" in
          local) for_line="this computer only (mode local)" ;;
          network) for_line="the local network (mode network${host:+, $host}${owner:+, owner $owner})" ;;
          *) for_line="a team server at ${public_url:-$host}${owner:+, owner $owner}" ;;
        esac
      fi
      [ -z "$switch_from" ] || for_line="$for_line, switched from mode $switch_from"
      printf '  For      %s\n' "$for_line"
    fi
    [ "$log_keep" = 0 ] || printf '  Log      %s\n' "$log"
    [ -z "$channel_note" ] || note "$channel_note"
    printf '\n'
  fi

  # 1. the archive: downloaded (a terminal sees it turn), checked against SHA256SUMS and unpacked
  if [ -n "$archive" ]; then
    if [ -n "$dl_url" ]; then step Download; else step Archive; fi
    if [ -n "$dl_url" ]; then
      # a terminal sees how much is in (the same request, its headers kept: see dl_progress)
      [ "$fancy" = 0 ] || { dl_hdr="$work/download.headers" spin_dl="$archive"; }
      quiet fetch "$dl_url" -o "$archive" || die "$qrc" "install.sh: could not download $dl_url"
      dl_hdr="" spin_dl=""
      if [ -z "$sums" ] && fetch "$(dirname "$dl_url")/SHA256SUMS" -o "$work/SHA256SUMS" 2>> "$log"; then sums="$work/SHA256SUMS"; fi
    elif [ -f "$(dirname "$archive")/SHA256SUMS" ]; then sums="$(dirname "$archive")/SHA256SUMS"
    fi
    if [ -n "$sums" ]; then sumcheck "$archive" "$sums"
    elif [ -n "$dl_url" ]; then nosums "the archive at $dl_url"
    else nosums "$archive"
    fi
    quiet tar -xzf "$archive" -C "$work"
    src="$(find "$work" -mindepth 1 -maxdepth 1 -type d -name 'halo-*' | head -n 1)"
    ok "$said"
  fi

  # 2. the program and the UI
  step Program
  [ -x "$src/halo" ] && [ -d "$src/ui" ] || die 1 "install.sh: $src has no halo program and ui folder"
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
  ok "Installed: $("$halo" --version) in $halo"
  case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *)
      if [ "$os" = darwin ]; then
        # zsh is the shell of macOS, and a new Terminal window reads ~/.zprofile
        pb="$prefix/bin"; [ "$prefix" != "$HOME/.local" ] || pb='$HOME/.local/bin'
        note "Note: $prefix/bin is not in your PATH yet. Add this line to ~/.zprofile and open a new terminal:  export PATH=\"$pb:\$PATH\""
      else
        note "Note: $prefix/bin is not in your PATH yet. Ubuntu adds ~/.local/bin at the next login (open a new terminal); elsewhere add to your shell profile:  export PATH=\"$prefix/bin:\$PATH\""
      fi ;;
  esac
  [ "$binary_only" = 0 ] || return 0

  if [ "$full" = 0 ]; then
    # no terminal and no choice: the old way, said aloud (a server wants --mode server --host <domain>)
    if [ "$init" = 1 ] && [ ! -f "$data/install.json" ]; then
      step Mode
      quiet "$halo" init --mode local
      ok "local (this computer only)"
      note "Note: no --mode and no terminal to ask on: mode local (this computer only). Choose again with: halo init --mode ${modes#local|} --force"
    fi
    next_line
    return 0
  fi

  # 3. the mode, once and right the first time; an installation that exists is never overwritten from here
  if [ -n "$have_mode" ]; then
    step Mode
    ok "mode $have_mode${have_host:+, $have_host}: an installation exists in $data; it stays as it is"
    if [ -z "$mode" ] || { [ "$mode" = "$have_mode" ] && { [ -z "$host" ] || [ "$host" = "$have_host" ]; }; }; then
      [ -z "$public_url" ] || note "--public-url is not applied to it: halo init --mode $have_mode --public-url $public_url --force"
    else
      echo "Note: an installation exists in $data (mode $have_mode, $have_host) and it stays. To change it (your settings are kept): halo init --mode $mode${host:+ --host $host}${public_url:+ --public-url $public_url} --force" >&2
    fi
    init=0
  elif [ "$init" = 1 ]; then
    said_local=0
    [ -n "$mode" ] || { mode=local; said_local=1; }
    step Mode
    set -- init --mode "$mode" --engine "$engine"
    # a switch (V-714): the service of the old mode goes first, and init keeps the engine, git and the bind of what is there
    if [ -n "$switch_from" ]; then
      service_off
      set -- init --mode "$mode" --force
      [ "$engine_named" = 0 ] || set -- "$@" --engine "$engine"
    fi
    [ -z "$host" ] || set -- "$@" --host "$host"
    [ -z "$public_url" ] || set -- "$@" --public-url "$public_url"
    quiet "$halo" "$@"
    case "$mode" in
      local) ok "local (this computer only)${switch_from:+ (was $switch_from)}" ;;
      *)
        # the address as halo init chose it when none was given (network: the LAN address as <ip>.sslip.io)
        where="${public_url:-$host}"
        [ -n "$where" ] || where="$(grep -o '"host": *"[^"]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
        ok "$mode, $where${switch_from:+ (was $switch_from)}" ;;
    esac
    if [ "$said_local" = 1 ] && [ "$os" = darwin ]; then note "Mode: local (this computer only). For the local network: --mode network"
    elif [ "$said_local" = 1 ]; then note "Mode: local (this computer only). For a team server: --mode server --host <domain>"; fi
  fi

  # 4. the engine, runtime images, linger and the service: halo doctor --fix. Every command that runs as root is named
  # first, and only those run (V-689).
  seen_visible=0
  if [ "$no_engine" = 0 ]; then
    ename="$(grep -o '"engine": *"[a-z]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4)" || ename=""
    case "$ename" in podman) ename=Podman ;; docker) ename=Docker ;; *) ename="Podman or Docker" ;; esac
    step "Engine ($ename)"
    goon="$halo doctor --fix"
    if ! engine_fix; then
      [ "$seen_visible" = 0 ] || die 1 "install.sh: something is not in order yet. Read the lines above (each says the command that fixes it), then run: halo doctor --fix"
      die 1 "install.sh: something is not in order yet. Read the last lines of the doctor below (each problem names the command that fixes it), then run: halo doctor --fix"
    fi
    ok "$ename, the runtime images and the service are in order$(took)"
    if [ "$images" = all ]; then
      step "PHP images"
      quiet "$halo" images build all
      ok "built$(took)"
    fi
  elif [ "$no_service" = 0 ]; then
    step Service
    goon="$halo service install"
    if [ "$eff_mode" = local ] || [ "$os" = darwin ]; then quiet "$halo" service install # a user unit, or a LaunchAgent: no root
    elif ! as_root unit "$halo" service install; then
      [ "$seen_visible" = 0 ] || die 1 "install.sh: the service could not be installed; read the lines above, then run: $goon"
      die 1 "install.sh: the service could not be installed; read the last lines below, then run: $goon"
    fi
    if [ "$os" = darwin ]; then ok "LaunchAgent com.fromorbit.halo"; else ok "halo.service"; fi
  fi

  # 5. wait until Halo answers
  step Start
  spin_start
  n=0
  until "$halo" health >/dev/null 2>&1; do
    n=$((n + 1))
    if [ "$n" -gt 60 ]; then
      [ "$os" = linux ] || die 1 "install.sh: Halo does not answer. See: halo service status, launchctl print gui/$(id -u)/com.fromorbit.halo"
      die 1 "install.sh: Halo does not answer. See: halo service status, journalctl -u halo (or --user -u halo)"
    fi
    sleep 1
  done
  spin_stop
  ok "Halo answers$(took)"

  # 6. the owner, when there are accounts (a Halo that has its owner already has no setup-code any more)
  accounts="$(grep -o '"accounts": *"[a-z]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  owner_done=""
  if [ "$accounts" = on ] && [ ! -f "$data/setup-code" ]; then
    owner_done="the owner exists already"
    [ "$owner_step" = 0 ] || { step Owner; skip "$owner_done"; }
  elif [ "$accounts" = on ] && [ -n "$owner" ] && [ -n "${HALO_OWNER_PASSWORD:-}" ]; then
    step Owner
    quiet owner_from_env
    unset HALO_OWNER_PASSWORD
    owner_done="$owner"
    ok "$owner"
  elif [ "$accounts" = on ] && [ -n "$owner" ] && [ "$tty" = 1 ]; then
    step Owner
    printf '%s: choose a password (at least 10 characters)\n' "$owner"
    "$halo" setup --name "$owner" < /dev/tty
    owner_done="$owner"
    resume; ok "$owner"
  elif [ "$accounts" = on ] && [ "$tty" = 1 ] && [ "$yes" = 0 ]; then
    step Owner
    printf 'the first account: choose a name and a password\n'
    "$halo" setup < /dev/tty
    owner_done="the owner"
    resume; ok "made"
  elif [ "$owner_step" = 1 ]; then
    step Owner
    skip "not made: this Halo has no accounts"
  fi

  # 7. Orbit (fromorbit.dev): with accounts a person at the terminal is asked once to link this Halo to a team there; the
  # outcome, or how to do it later, goes in the summary (V-714)
  orbit_link

  # 8. the last lines: where to open Halo and what to do first
  summary
}

# The guided setup (V-689, V-714): which mode (network by default; on a Mac no team server), and for a mode with accounts
# the address and the owner. An installation that exists is shown with its mode, the default: Enter keeps it, another
# number switches (`switch_from`; the Mode step removes the old service and runs init --force). Every question has a default.
guided() {
  title
  printf '\n'
  now=0
  case "$have_mode" in local) now=1 ;; network) now=2 ;; server) now=3 ;; esac
  last=3
  [ "$os" = linux ] || last=2
  if [ "$now" = 0 ]; then printf 'Who is Halo for?\n' > /dev/tty
  else printf 'Halo is installed here in mode %s%s. Keep it (Enter) or switch:\n' "$have_mode" "${have_host:+ at $have_host}" > /dev/tty; fi
  k=1
  for what in 'only this computer (local)' 'this computer and others on the network, with accounts (network)' \
    'a team server with its own domain, with accounts (server)'; do
    if [ "$k" -le "$last" ]; then
      if [ "$k" = "$now" ]; then printf '  %s) %s  %s<- now%s\n' "$k" "$what" "$D" "$N" > /dev/tty
      else printf '  %s) %s\n' "$k" "$what" > /dev/tty; fi
    fi
    k=$((k + 1))
  done
  [ "$last" = 3 ] || printf '  %s(a team server runs on Linux)%s\n' "$D" "$N" > /dev/tty
  def=2
  [ "$now" = 0 ] || def="$now"
  while :; do
    ask 'Choose' "$def"
    case "$answer" in 1|2) break ;; 3) [ "$last" = 2 ] || break ;; esac
    printf '  Type a number from 1 to %s.\n' "$last" > /dev/tty
  done
  case "$answer" in 1) pick=local ;; 2) pick=network ;; *) pick=server ;; esac
  if [ "$now" != 0 ]; then
    if [ "$pick" = "$have_mode" ]; then printf '\n' > /dev/tty; return 0; fi # kept: the Mode step says it stays
    switch_from="$have_mode" have_mode="" have_host=""
  fi
  mode="$pick"
  if [ "$mode" = local ]; then
    printf '\n' > /dev/tty
    return 0
  fi
  # a Mac finds its LAN address itself (halo init), and --host is no flag there (V-690)
  [ "$os" = darwin ] || ask_host
  me="$(printf '%s' "${USER:-$(id -un 2>/dev/null || true)}" | tr 'A-Z' 'a-z')"
  printf '%s' "$me" | grep -Eq '^[a-z0-9][a-z0-9._-]{1,31}$' || me=""
  printf '\nThe owner: the first account, who adds the others. Its password is asked at the end.\n' > /dev/tty
  while :; do
    ask 'Owner' "$me"
    owner="$answer"
    if printf '%s' "$owner" | grep -Eq '^[a-z0-9][a-z0-9._-]{1,31}$'; then break; fi
    # no answer at all: halo setup asks the name with the password
    if [ "$eof" = 1 ]; then owner=""; break; fi
    printf '  A name is 2 to 32 of a-z, 0-9, dot, dash and underscore, starting with a letter or digit.\n' > /dev/tty
  done
  printf '\n' > /dev/tty
}

# The address of a mode with accounts: for a server its domain, for the network this computer's address on it. The proposal
# is the LAN address as <ip-with-dashes>.sslip.io; a typed IP becomes its sslip.io name. The network may go without one
# (halo init then says what it chose); a server may not.
ask_host() {
  ip="$(lan_ip)"
  suggest=""
  [ -z "$ip" ] || suggest="$(printf '%s' "$ip" | tr . -).sslip.io"
  if [ "$mode" = server ]; then
    q=Domain
    printf '\nThe domain of the server: every space gets an address under it (<space>.<domain>), so <domain> and *.<domain>\nmust point to this computer. No domain of your own? <ip-with-dashes>.sslip.io is wildcard DNS for an IP.\n' > /dev/tty
    [ -z "$ip" ] || printf 'The proposal is the LAN address of this computer (%s). On a cloud VM behind NAT, type its public IP or your domain.\n' "$ip" > /dev/tty
  else
    q=Address
    printf '\nThe address of this computer on the network: Halo opens at it and every space under it (<space>.<address>).\n<ip-with-dashes>.sslip.io is wildcard DNS for an IP, so no DNS of your own is needed.\n' > /dev/tty
    [ -z "$ip" ] || printf 'The proposal is the LAN address of this computer (%s).\n' "$ip" > /dev/tty
    # WSL 2 in its default (NAT) network has an address of its own that the rest of the network cannot reach
    if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
      printf 'This is WSL: other computers reach it only with mirrored networking (networkingMode=mirrored in .wslconfig on\nWindows; then the proposal is the address of Windows), or type the address of Windows with a port forward.\n' > /dev/tty
    fi
  fi
  while :; do
    ask "$q" "$suggest"
    host="$(printf '%s' "$answer" | tr 'A-Z' 'a-z' | sed 's#^[a-z]*://##; s#/*$##')"
    # the network without a proposal and without an answer: halo init chooses
    [ -n "$host" ] || [ "$mode" = server ] || break
    # an IP is turned into its sslip.io name, so the addresses of the spaces work too
    if printf '%s' "$host" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then host="$(printf '%s' "$host" | tr . -).sslip.io"; fi
    if printf '%s' "$host" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
      case "$host" in localhost|*.localhost) ;; *) break ;; esac
    fi
    [ "$eof" = 0 ] || [ "$mode" = network ] || die 2 "install.sh: a server needs its own domain. Run: sh install.sh --mode server --host <domain> (no domain of your own: --host <ip-with-dashes>.sslip.io, for example 192-168-1-50.sslip.io)"
    [ "$eof" = 0 ] || { host=""; break; }
    printf '  A domain is a name like halo.example.com (letters, digits, dashes and dots).\n' > /dev/tty
  done
}

# Before a switch (V-714): the service of the old mode stops and goes, so the new mode installs its own (a user unit for
# local, a system unit for network and server, a LaunchAgent on a Mac) and starts in it; the doctor's repair does that,
# with its root commands shown as always. A system unit needs root to go: its three commands are shown and asked first.
service_off() {
  if [ "$os" = linux ] && [ -f /etc/systemd/system/halo.service ]; then
    break_line
    printf '      The service of mode %s is a system unit; to switch it is stopped and removed. These commands run as root (sudo):\n' "$switch_from" > /dev/tty
    printf '         sudo systemctl disable --now halo.service\n         sudo rm -f /etc/systemd/system/halo.service\n         sudo systemctl daemon-reload\n' > /dev/tty
    if ! consent Y; then
      finish "$R" "$m_no" "not approved: the mode stays $switch_from"
      printf 'install.sh: the root commands did not run, so the mode stays %s. halo is installed in %s.\n' "$switch_from" "$halo" >&2
      printf 'To switch by hand: sudo systemctl disable --now halo.service; sudo rm -f /etc/systemd/system/halo.service; %s init --mode %s --force; %s doctor --fix\n' "$halo" "$mode" "$halo" >&2
      exit 1
    fi
    resume
    quiet sudo systemctl disable --now halo.service || die 1 "install.sh: could not stop the service; the mode stays $switch_from. Try: sudo systemctl disable --now halo.service"
    quiet sudo rm -f /etc/systemd/system/halo.service
    quiet sudo systemctl daemon-reload || :
  else
    quiet "$halo" service remove || die 1 "install.sh: could not stop the service of mode $switch_from; the mode stays. See: $halo service status"
  fi
}

# Orbit (fromorbit.dev), once Halo answers and the owner exists (V-714): with accounts, at a terminal and without --yes, one
# question; yes runs `halo orbit pair` on the terminal (its code and link are shown there and kept for the summary). No, no
# terminal, --yes or mode local: the summary says how to do it later.
orbit_link() {
  if [ "$accounts" != on ]; then
    orbit_row="needs accounts: install again, choose network"
    return 0
  fi
  case ":$PATH:" in *":$prefix/bin:"*) oh=halo ;; *) oh="$halo" ;; esac
  orbit_row="not linked; later: $oh orbit pair"
  st="$("$halo" orbit status --json 2>/dev/null | tr -d '\n')" || st=""
  if printf '%s' "$st" | grep -q '"state": *"paired"'; then orbit_row="linked (see: halo orbit status)"; return 0; fi
  [ "$tty" = 1 ] && [ "$yes" = 0 ] || return 0
  printf '\n' > /dev/tty
  ask 'Link this Halo to a team on Orbit (fromorbit.dev)?' 'Y/n'
  [ "$eof" = 0 ] || return 0
  case "$answer" in Y/n|[Yy]|[Yy][Ee][Ss]|[Jj]|[Jj][Aa]) ;; *) return 0 ;; esac
  # its own words on the terminal (also when the output goes to a file), the code read back for the summary
  if "$halo" orbit pair < /dev/tty > /dev/tty 2>&1; then
    st="$("$halo" orbit status --json 2>/dev/null | tr -d '\n')" || st=""
    code="$(printf '%s' "$st" | sed -n 's/.*"userCode": *"\([^"]*\)".*/\1/p')"
    at="$(printf '%s' "$st" | sed -n 's/.*"verificationUri": *"\([^"]*\)".*/\1/p')"
    if [ -n "$code" ]; then orbit_row="approve code $code at ${at:-https://fromorbit.dev}"
    else orbit_row="pairing started; see: $oh orbit status"; fi
  else
    orbit_row="not linked (the reason is above); try again: $oh orbit pair"
  fi
  printf '\n'
}

# The end without a full install: what to do next. A Halo that already runs as a service (or by hand) is never told to
# start with halo serve; it runs the old program until it restarts.
next_line() {
  run=""
  if [ "$os" = darwin ] && [ -f "$agent" ]; then run="launchctl kickstart -k gui/$(id -u)/com.fromorbit.halo"
  elif [ -f /etc/systemd/system/halo.service ]; then run="sudo systemctl restart halo.service"
  elif [ -f "$unit" ]; then run="systemctl --user restart halo.service"
  fi
  if [ -n "$run" ]; then
    printf '\nNext: Halo runs as a service; restart it to run this version: %s\n' "$run"
  else
    printf '\nNext: halo serve (or open the Halo app, which starts it). For the engine, images and a service: halo doctor --fix\n'
  fi
}

# The LAN IPv4 of this computer: HALO_LAN_IP (as halo init has it), the source address of the default route (a lookup in
# the routing table: nothing is sent), else the first IPv4 of hostname -I; nothing when there is none. Never a service on
# the internet: behind NAT the person types the public address.
lan_ip() {
  [ -z "${HALO_LAN_IP:-}" ] || { printf '%s\n' "$HALO_LAN_IP"; return 0; }
  if [ "$os" = darwin ]; then # macOS: the interface of the default route, and its address
    dev="$(route -n get default 2>/dev/null | sed -n 's/^ *interface: *\([^ ]*\).*/\1/p' | head -n 1)" || dev=""
    got=""
    [ -z "$dev" ] || got="$(ipconfig getifaddr "$dev" 2>/dev/null)" || got=""
    case "$got" in *.*.*.*) printf '%s\n' "$got" ;; esac
    return 0
  fi
  got="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9][0-9.]*\).*/\1/p' | head -n 1)" || got=""
  [ -n "$got" ] || got="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)" || got=""
  case "$got" in *.*.*.*) printf '%s\n' "$got" ;; esac
}

# Runs <command> (halo doctor --fix, or halo service install) so that nothing runs as root that the person did not see
# (V-689). `halo doctor --root-plan` names every such command: the root steps and what the repairs run with sudo themselves
# (`all`), or what `halo service install` runs for a system unit (`unit`). They are shown on the terminal (on standard
# output without one), and a person answers one "Continue?" (Enter is yes; n, or the end of the input, is no); with --yes
# they are shown and not asked. Only the commands shown may run: their argv go to the command as HALO_SUDO_APPROVED, and
# Halo refuses any other (the argv are approved, not what a file holds: so the unit reaches root on standard input). When
# the command stops on a root command it was not given (the doctor finds one after Podman is in), the new ones are shown
# and asked again. Without a terminal and without --yes nothing is asked and nothing runs as root (V-116).
# On a Mac (`user`, V-690) the same holds for what changes the Mac without root (Homebrew, Colima, a Podman machine): the
# `user` list of the plan is shown as commands that run without sudo, asked and handed over as HALO_USER_APPROVED, with an
# empty HALO_SUDO_APPROVED beside it, so Halo refuses any sudo there.
as_root() { # <all|unit|user> <command...>
  which="$1"; shift
  extra=""
  [ "$which" = unit ] || extra=--yes
  if [ "$tty" = 0 ] && [ "$yes" = 0 ]; then
    [ "$which" = unit ] || { quiet "$@"; return; } # the doctor without --yes asks, finds no terminal and changes nothing
    if rows="$(root_plan_rows unit)" && [ -n "$rows" ]; then list_root "$rows"; fi
    die 1 "install.sh: this needs root (sudo) and there is no terminal to ask on. Add --yes (the commands are shown, not asked), or run it with ssh -t."
  fi
  approved="$work/approved.jsonl"
  shown="$work/approved.rows"
  : > "$approved"
  : > "$shown"
  round=0
  while :; do
    round=$((round + 1))
    # a plan this script cannot read, or a halo that does not keep to the list (no "gate"): the doctor names its root
    # commands itself, on the screen (and asks without --yes); for halo service install they are asked here in general
    if ! rows="$(root_plan_rows "$which")" || { [ "$which" = unit ] && [ -z "$rows" ]; }; then
      if [ "$which" = unit ]; then unit_unlisted "$@"; return; fi
      [ "$yes" = 1 ] || extra=""
      visible "$@" $extra
      return
    fi
    new="$(printf '%s\n' "$rows" | awk -v f="$shown" 'FILENAME == f { seen[$0] = 1; next } NF && !seen[$0]' "$shown" -)"
    # after a failure: nothing new to approve, so the failure is a failure
    [ -n "$new" ] || [ "$round" = 1 ] || return 1
    if [ -n "$new" ]; then
      list_root "$new" "$which"
      [ "$yes" = 1 ] || consent Y || stop_root "$which"
      printf '%s\n' "$new" >> "$shown"
      key=steps; [ "$which" != user ] || key=user
      printf '%s\n' "$new" | sed "s/^[^|]*|\\(.*\\)\$/{\"$key\":[{\"argv\":[\\1]}]}/" >> "$approved"
      [ "$step_open" = 1 ] || resume
    fi
    if [ "$which" = user ]; then
      : > "$work/none.jsonl"
      quiet env HALO_USER_APPROVED="$approved" HALO_SUDO_APPROVED="$work/none.jsonl" "$@" $extra && return 0
      [ "$round" -lt 4 ] || return 1
      continue
    fi
    if ! sudo_ready; then
      visible env HALO_SUDO_APPROVED="$approved" "$@" $extra
      return
    fi
    quiet env HALO_SUDO_APPROVED="$approved" "$@" $extra && return 0
    [ "$round" -lt 4 ] || return 1
  done
}

# The engine step: halo doctor --fix through as_root, with the root commands of the plan on Linux and on a Mac (V-690),
# where nothing runs as root, the commands that change the Mac without it (`user`: Homebrew, Colima, a Podman machine).
engine_fix() {
  if [ "$os" = darwin ]; then as_root user "$halo" doctor --fix; else as_root all "$halo" doctor --fix; fi
}

# halo service install, when its root commands cannot be listed here (an older halo, a plan that cannot be read): said in
# general and asked with no as the default (with --yes it runs); the command shows its own lines.
unit_unlisted() {
  if [ "$yes" = 0 ]; then
    break_line
    printf '      halo service install runs sudo commands for the system unit (/etc/halo, /etc/halo/secrets,\n      /etc/systemd/system/halo.service, systemctl); this halo cannot list them here.\n' > /dev/tty
    consent N || stop_root
  fi
  visible "$@"
}

# The commands of `halo doctor --root-plan` that run as root, one per line as `explain|argv` (argv as its JSON array
# items): those of the repairs (`all`) or those of the system unit (`unit`). Fails when this halo does not keep to an
# approved list (no `"gate":1`), and when the plan cannot be shown exactly as it would run: an item with a quote, a
# backslash, `|` or `]` makes the whole plan unreadable, so what is shown is always what is approved.
root_plan_rows() { # <all|unit|user>
  plan="$("$halo" doctor --root-plan 2>> "$log")" || return 1
  case "$plan" in '{"steps":'*'"gate":1}') ;; *) return 1 ;; esac
  case "$1" in
    all) plan="$(printf '%s' "$plan" | sed 's/,"unit":\[.*$//; s/,"user":\[.*$//')" ;;
    *) plan="$(printf '%s' "$plan" | sed -n "s/.*\"$1\":\\[/[/p")" ;;
  esac
  rows="$(printf '%s\n' "$plan" | sed 's/{"explain"/\
{"explain"/g' | sed -n 's/^{"explain":"\([^"\\]*\)","argv":\[\([^]\\]*\)\].*/\1|\2/p')"
  want="$(printf '%s' "$plan" | grep -o '"explain"' | wc -l | tr -d ' ')"
  have=0
  [ -z "$rows" ] || have="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
  [ "$want" = "$have" ] || return 1
  [ -z "$rows" ] || ! printf '%s\n' "$rows" | grep -Evq '^[^"\\|]*\|"[^"\\|]*"(,"[^"\\|]*")*$' || return 1
  [ -z "$rows" ] || printf '%s\n' "$rows"
}

# The commands that will run as root, grouped by what they are for: on the terminal when there is one (also when the
# output goes to a file), else on standard output.
list_root() { # <rows> [user]
  if [ "$tty" = 1 ] && [ ! -t 1 ]; then root_lines "$@" > /dev/tty; return; fi
  break_line
  if [ "$tty" = 1 ]; then root_lines "$@" > /dev/tty; else root_lines "$@"; fi
}
root_lines() {
  if [ "${2:-}" = user ]; then pre="" what="These commands run (no sudo)"
  elif [ "$(id -u)" = 0 ]; then pre="" what="These commands run as root"
  else pre="sudo " what="These commands run as root (sudo)"; fi
  printf '      %s%s:%s\n' "$B" "$what" "$N"
  printf '%s\n' "$1" | awk -F'|' -v pre="$pre" '
    $1 != last { n++; printf "      %d. %s\n", n, $1; last = $1 }
    { a = $2; gsub(/","/, " ", a); gsub(/"/, "", a); printf "         %s%s\n", pre, a }'
}

# One "Continue?" on the terminal, with yes (Y) or no (N) as what Enter means; n, or the end of the input (Ctrl-D), is no.
consent() { # <Y|N>
  while :; do
    if [ "$1" = Y ]; then ask '      Continue?' 'Y/n'; else ask '      Continue?' 'y/N'; fi
    [ "$eof" = 0 ] || return 1
    case "$answer" in Y/n|[Yy]|[Yy][Ee][Ss]|[Jj]|[Jj][Aa]) return 0 ;; y/N|[Nn]|[Nn][Oo]|[Nn][Ee][Ee]) return 1 ;; esac
  done
}

# The person said no: what is done, that the root commands did not run, and the commands to go on or to choose again.
stop_root() { # [user]
  cur="$(grep -o '"mode": *"[a-z]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  [ "$step_open" = 1 ] || resume
  finish "$R" "$m_no" "not approved: the commands above did not run"
  if [ "${1:-}" = user ]; then as="" which_cmds="commands"; else as=" as root" which_cmds="root commands"; fi
  printf 'install.sh: the commands above did not run%s, so this step is not done.\n' "$as" >&2
  printf 'Done: halo is installed in %s%s.\n' "$halo" "${cur:+, in mode $cur ($data/install.json)}" >&2
  printf 'To go on: %s (it names the %s and asks again). Another mode: %s init --mode %s --force\n' "$goon" "$which_cmds" "$halo" "$modes" >&2
  exit 1
}

# sudo answers without a password before a quiet step starts: asked here on the terminal, while nothing draws over it,
# and kept alive by the turning mark. False when sudo would still ask during the step: then it runs on the screen.
sudo_ready() {
  [ -s "$shown" ] && [ "$(id -u)" != 0 ] || return 0
  if ! sudo -n true 2>/dev/null; then
    [ "$tty" = 1 ] || return 1
    break_line
    sudo -v < /dev/tty || return 1
    resume
    sudo -n true 2>/dev/null || return 1
  fi
  keep_sudo=1
}

# A command on the screen, with the terminal: its own lines (and questions) are seen; a failure points above, not below.
visible() { # <command...>
  break_line
  step_quiet=0
  seen_visible=1
  if [ "$tty" = 1 ]; then "$@" < /dev/tty || return 1; else "$@" < /dev/null || return 1; fi
  resume
}

# The owner from HALO_OWNER_PASSWORD, on standard input (never an argument, never the log).
owner_from_env() { printf '%s\n' "$HALO_OWNER_PASSWORD" | "$halo" setup --name "$owner" --password-stdin; }

# The last lines: where Halo is, the line for the app, the owner and what to do next.
summary() {
  install_mode="$(grep -o '"mode": *"[a-z]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  install_host="$(grep -o '"host": *"[^"]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  row() { pad="$(printf '%-18s' "$1")"; printf '  %s%s%s%s%s\n' "$B" "$1" "$N" "${pad#"$1"}" "$2"; }
  printf '\n'
  case "$install_mode" in
    local|"")
      card 'this computer only' 'Open Halo:' 'http://127.0.0.1:7788' 'First workspace:' 'halo repo scan <folder with your app>' \
        'Orbit:' "$orbit_row" && return 0
      printf '%s%s%s %sHalo is running (this computer only).%s\n\n' "$G" "$m_ok" "$N" "$B" "$N"
      row 'Open Halo:' 'http://127.0.0.1:7788'
      row 'First workspace:' 'halo repo scan <folder with your app>'
      row 'Orbit:' "$orbit_row"
      return 0 ;;
  esac
  public="$(grep -o '"publicUrl": *"[^"]*"' "$data/install.json" 2>/dev/null | cut -d'"' -f4 || true)"
  url="http://${install_host}:7788"
  [ -z "$public" ] || url="$public"
  # a later ssh command does not read the profile that puts ~/.local/bin in the PATH: say the path that always works
  case ":$PATH:" in *":$prefix/bin:"*) h=halo ;; *) h="$halo" ;; esac
  caddy=""
  if [ -n "$public" ] && [ "${public#https://}" != "$public" ]; then
    mkdir -p "$data/caddy"
    if caddy="$("$halo" caddyfile --out "$data/caddy/Caddyfile" 2>&1)"; then caddy_ok=1; else caddy_ok=0; fi
  fi
  if card "$install_mode, accounts on" 'Open Halo:' "$url" 'Orbit:' "$orbit_row"; then printf '\n'; else
    printf '%s%s%s %sHalo is running (%s, accounts on).%s\n\n' "$G" "$m_ok" "$N" "$B" "$install_mode" "$N"
    row 'Open Halo:' "$url"
    row 'Orbit:' "$orbit_row"
  fi
  row 'In the Halo app:' "Host toevoegen (add host) > $url"
  if [ -n "$public" ] && [ "${public#https://}" != "$public" ]; then
    # behind a reverse proxy: Halo listens on this computer only, the proxy is the front door (80 and 443, nothing else)
    spaces="$(printf '%s' "$public" | sed 's#^\([a-z]*://\)#\1<space>.#')"
    row 'Spaces open at:' "$spaces   (Halo itself listens on 127.0.0.1; open only ports 80 and 443: sudo ufw allow 80/tcp; sudo ufw allow 443/tcp)"
    if [ "$caddy_ok" = 1 ]; then
      row 'Caddy:' "the configuration is in $data/caddy/Caddyfile:"
      printf '%s\n' "$caddy" | sed 's/^/                    /'
    else
      row 'Caddy:' "the configuration could not be made; see: halo caddyfile --help" >&2
    fi
  else
    fw="(open ports 7788 and 7790: sudo ufw allow 7788/tcp; sudo ufw allow 7790/tcp)"
    [ "$os" = linux ] || fw="(ports 7788 and 7790; with the macOS firewall on, allow halo in System Settings > Network > Firewall)"
    row 'Spaces open at:' "http://<space>.${install_host}:7790   $fw"
  fi
  if [ -n "$owner_done" ] && [ -n "$owner" ] && [ "$owner_done" = "$owner" ]; then
    row 'Owner:' "$owner (log in with your password)"
  elif [ -n "$owner_done" ]; then
    row 'Owner:' "$owner_done"
  else
    row 'Owner:' "not made yet: $h setup --name <name>"
  fi
  row 'Add someone:' "$h users create anna --role member --password -   (password on standard input; --role admin for an admin)"
  case "$public" in
    https://*) ;;
    *) printf '  %sNote: without TLS passwords travel unencrypted over the network; put a reverse proxy with TLS in front (docs: server.md).%s\n' "$Y" "$N" ;;
  esac
}

# The first lines of the summary as a card, on a terminal: the headline and the address (for this computer also the first
# command) in a box, rounded in UTF-8. Every row keeps two spaces from the border, so a row copied with the mouse has no
# border in it, and the address is a link where the terminal is known to open one (OSC 8). A mint satellite goes once
# round the card and stays on top. False, with nothing drawn, without a terminal, in CI, or when the card is wider than
# the terminal: then the summary is the lines it always was.
card() { # <what runs> <label> <value> [<label> <value> [<label> <value>]]
  [ "$logo" = 1 ] || return 1
  head="$m_ok Halo is running ($1)."
  l1="$2" v1="$3" l2="${4:-}" v2="${5:-}" l3="${6:-}" v3="${7:-}"
  [ -n "$v2" ] || l2=""
  [ -n "$v3" ] || l3=""
  iw="$(wid "$head")"
  for v in "$v1" "$v2" "$v3"; do # a row is two spaces, the label in 18 and the value
    [ -n "$v" ] || continue
    w=$((20 + $(wid "$v")))
    [ "$w" -le "$iw" ] || iw="$w"
  done
  cw=$((iw + 6)) ch=7 # lines: the border, a blank, the headline, a blank, the rows, a blank, the border
  [ -z "$l2" ] || ch=$((ch + 1))
  [ -z "$l3" ] || ch=$((ch + 1))
  [ "$cw" -le "$wide" ] || return 1
  if [ "$utf" = 1 ]; then tl='╭' tr='╮' bl='╰' br='╯' hz='─' vt='│' sat='•'; else tl='+' tr='+' bl='+' br='+' hz='-' vt='|' sat='o'; fi
  osc8=0
  case "${TERM_PROGRAM:-}" in iTerm.app|WezTerm|vscode|ghostty) osc8=1 ;; esac
  case "${TERM:-}" in *kitty*) osc8=1 ;; esac
  [ -z "${WT_SESSION:-}" ] || osc8=1
  case "${VTE_VERSION:-}" in ''|*[!0-9]*) ;; *) [ "$VTE_VERSION" -lt 5000 ] || osc8=1 ;; esac
  # the top border, with the satellite where it rests (three cells from the corner) unless it is still to come round
  rule="" k=2
  while [ "$k" -lt "$cw" ]; do rule="$rule$hz"; k=$((k + 1)); done
  left="${rule#"$hz$hz$hz"}"
  if [ "$anim" = 1 ]; then printf '%s%s%s%s\n' "$V" "$tl" "$rule" "$tr$N"
  else printf '%s%s%s%s%s%s%s%s%s\n' "$V" "$tl" "$left" "$N" "$B$M" "$sat" "$N" "$V" "$hz$hz$tr$N"; fi
  inside() { printf "%s%s%s  %s%$((iw - $2))s  %s%s%s\n" "$V" "$vt" "$N" "$1" '' "$V" "$vt" "$N"; } # <coloured text> <width>
  inside '' 0
  inside "$G$m_ok$N $B${head#"$m_ok "}$N" "$(wid "$head")"
  inside '' 0
  for k in 1 2 3; do
    case "$k" in 1) l="$l1" v="$v1" ;; 2) l="$l2" v="$v2" ;; *) l="$l3" v="$v3" ;; esac
    [ -n "$l" ] || continue
    pad="$(printf '%-18s' "$l")"
    case "$v" in
      http://*|https://*) if [ "$osc8" = 1 ]; then cv="$B$M$(printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$v" "$v")$N"; else cv="$B$M$v$N"; fi ;;
      *) cv="$v" ;;
    esac
    inside "  $B$l$N${pad#"$l"}$cv" $((20 + $(wid "$v")))
  done
  inside '' 0
  printf '%s%s%s%s\n' "$V" "$bl" "$rule" "$br$N"
  [ "$anim" = 1 ] || return 0
  # the satellite goes once round the card, clockwise in twelve steps of 40 ms, and comes to rest on top
  cursor_off
  per=$((2 * cw + 2 * ch - 4)) home=$((cw - 4)) prev=-1 k=1
  while [ "$k" -le 12 ]; do
    p=$(((home + k * per / 12) % per))
    if [ "$prev" -ge 0 ]; then edge "$prev"; put "$er" "$ec" "$V" "$eg"; fi
    edge "$p"; put "$er" "$ec" "$B$M" "$sat"
    prev="$p" k=$((k + 1))
    [ "$k" -gt 12 ] || sleep 0.04 || :
  done
  cursor_on
}
edge() { # <p>: the cell of the card's border at p, clockwise from the top left corner: its row er, column ec, glyph eg
  if [ "$1" -lt "$cw" ]; then
    er=0 ec="$1" eg="$hz"; [ "$ec" != 0 ] || eg="$tl"; [ "$ec" != $((cw - 1)) ] || eg="$tr"
  elif [ "$1" -lt $((cw + ch - 2)) ]; then er=$(($1 - cw + 1)) ec=$((cw - 1)) eg="$vt"
  elif [ "$1" -lt $((2 * cw + ch - 2)) ]; then
    er=$((ch - 1)) ec=$((2 * cw + ch - 3 - $1)) eg="$hz"; [ "$ec" != 0 ] || eg="$bl"; [ "$ec" != $((cw - 1)) ] || eg="$br"
  else er=$((2 * cw + 2 * ch - 4 - $1)) ec=0 eg="$vt"; fi
}
put() { # <row> <column> <colour> <glyph>: one cell of the card drawn again, from the line below it and back there
  cu=$((ch - $1))
  if [ "$2" -gt 0 ]; then printf '\033[%dA\r\033[%dC%s%s%s\r\033[%dB' "$cu" "$2" "$3" "$4" "$N" "$cu"
  else printf '\033[%dA\r%s%s%s\r\033[%dB' "$cu" "$3" "$4" "$N" "$cu"; fi
}
# The width of a text in characters: the bytes that continue a UTF-8 character are not counted.
wid() { printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '; }

main "$@"
