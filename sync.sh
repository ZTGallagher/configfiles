#!/usr/bin/env bash
# sync.sh — two-way sync between this repo and the live machine (macOS + Linux).
#
#   ./sync.sh backup   Copy live config files INTO the repo (then review, commit, push).
#   ./sync.sh restore  Set up a fresh machine: place all configs; on macOS also
#                      install Homebrew, brew bundle, devbox, nvm. Prints manual
#                      follow-ups at the end.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"

# "<repo-relative path>:<home-relative path>" — shared by both OSes
MAPPINGS=(
  "git/config:.gitconfig"
  "git/ignore:.config/git/ignore"
  "nvim/init.lua:.config/nvim/init.lua"
  "starship/starship.toml:.config/starship/starship.toml"
)

if [[ "$OS" == "Darwin" ]]; then
  MAPPINGS+=(
    "zsh/zshrc:.zshrc"
    "zsh/zprofile:.zprofile"
    "wezterm/macos/wezterm.lua:.config/wezterm/wezterm.lua"
    "karabiner/karabiner.json:.config/karabiner/karabiner.json"
    "ssh/config:.ssh/config"
    "brewfile/brewfile:brewfile"
  )
else
  MAPPINGS+=(
    "zsh/.zshrc_for_linux:.zshrc"
    "wezterm/linux/wezterm.lua:.config/wezterm/wezterm.lua"
    "fish/config.fish:.config/fish/config.fish"
    "fish/conf.d/xdg.fish:.config/fish/conf.d/xdg.fish"
  )
fi

# Top-level ~/.config entries we deliberately do NOT track (credentials,
# caches, machine state). scan/check warn about anything in ~/.config that
# is neither covered by MAPPINGS nor listed here — so every warning is an
# untriaged decision. To silence one, add its name here; to track it, add
# a mapping line to MAPPINGS instead.
UNTRACKED_OK=(
  gcloud    # auth tokens
  glab-cli  # gitlab token
  homebrew  # brew's own state
  gtk-3.0   # auto-generated
)

# Secret detection. backup REFUSES to copy a home file matching any of
# these into the (public!) repo, and check FAILS if a tracked repo file
# matches. Tune the list here if a pattern false-positives.
SECRET_PATTERNS=(
  'AKIA[0-9A-Z]{16}'                       # AWS access key id
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'     # any PEM private key
  'gh[pousr]_[A-Za-z0-9]{30,}'             # GitHub tokens
  'github_pat_[A-Za-z0-9_]{30,}'           # GitHub fine-grained PAT
  'glpat-[A-Za-z0-9_-]{20,}'               # GitLab PAT
  'xox[baprs]-[A-Za-z0-9-]{10,}'           # Slack tokens
  'sk-ant-[A-Za-z0-9_-]{20,}'              # Anthropic API key
  'AIza[0-9A-Za-z_-]{30,}'                 # Google API key
  '(password|secret|token|api_key)[[:space:]]*[=:][[:space:]]*"[^"]{8,}'  # generic quoted assignment
)

has_secret() {  # $1 = file; prints matching pattern and returns 0 on hit
  for p in "${SECRET_PATTERNS[@]}"; do
    if grep -Eq "$p" "$1" 2>/dev/null; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

SCAN_WARNINGS=0
scan() {
  SCAN_WARNINGS=0
  tracked=()
  for m in "${MAPPINGS[@]}"; do
    h="${m#*:}"
    if [[ "$h" == .config/* ]]; then
      rest="${h#.config/}"
      tracked+=("${rest%%/*}")
    fi
  done
  echo "==> Untracked entries in ~/.config"
  for entry in "$HOME"/.config/*; do
    if [[ ! -e "$entry" ]]; then continue; fi
    name="$(basename "$entry")"
    known=""
    for t in "${tracked[@]}" "${UNTRACKED_OK[@]}"; do
      if [[ "$name" == "$t" ]]; then known=1; break; fi
    done
    if [[ -n "$known" ]]; then continue; fi
    echo "    [WARN]  ~/.config/$name is not tracked"
    SCAN_WARNINGS=$((SCAN_WARNINGS+1))
  done
  if [[ $SCAN_WARNINGS -eq 0 ]]; then
    echo "    [ok]    everything in ~/.config is tracked or intentionally ignored"
  else
    echo "    For each: track it (add a line to MAPPINGS in sync.sh, then './sync.sh backup')"
    echo "    or silence it (add its name to UNTRACKED_OK in sync.sh)."
  fi

  if [[ "$OS" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    echo "==> Installed brew packages not in brewfile"
    pkg_drift="$(brew bundle cleanup --file="$REPO_DIR/brewfile/brewfile" 2>/dev/null \
      | awk '/^Would uninstall (formulae|casks):/{f=1;next} /^Would/{f=0} f' || true)"
    if [[ -z "$pkg_drift" ]]; then
      echo "    [ok]    everything installed is in the brewfile"
    else
      while IFS= read -r pkg; do
        echo "    [WARN]  $pkg installed but not in brewfile"
        SCAN_WARNINGS=$((SCAN_WARNINGS+1))
      done <<< "$pkg_drift"
      echo "    For each: add it to brewfile/brewfile, or 'brew uninstall' it."
    fi
  fi
}

backup() {
  blocked=0
  echo "==> Backing up live configs into $REPO_DIR ($OS)"
  for m in "${MAPPINGS[@]}"; do
    repo_file="$REPO_DIR/${m%%:*}"
    home_file="$HOME/${m#*:}"
    if [[ ! -f "$home_file" ]]; then
      echo "    skipped ~/${m#*:} (not found)"
    elif cmp -s "$home_file" "$repo_file"; then
      echo "    same    ~/${m#*:}"
    elif pat="$(has_secret "$home_file")"; then
      echo "    BLOCKED ~/${m#*:} — matches secret pattern '$pat'; NOT copied."
      echo "            Remove the secret (or tune SECRET_PATTERNS in sync.sh) and re-run."
      blocked=$((blocked+1))
    else
      mkdir -p "$(dirname "$repo_file")"
      cp "$home_file" "$repo_file"
      echo "    UPDATED ~/${m#*:} -> ${m%%:*}"
    fi
  done
  echo
  echo "==> Repo status — review, then commit and push:"
  git -C "$REPO_DIR" status --short
  if [[ $blocked -gt 0 ]]; then
    echo
    echo "WARNING: $blocked file(s) BLOCKED by the secret scan — see above."
    exit 1
  fi
}

place_files() {
  backup_dir="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"
  for m in "${MAPPINGS[@]}"; do
    repo_file="$REPO_DIR/${m%%:*}"
    home_file="$HOME/${m#*:}"
    if [[ ! -f "$repo_file" ]]; then
      echo "    skipped ${m%%:*} (not in repo)"
      continue
    fi
    if [[ -f "$home_file" ]] && cmp -s "$repo_file" "$home_file"; then
      echo "    same    ~/${m#*:}"
      continue
    fi
    if [[ -f "$home_file" ]]; then
      mkdir -p "$backup_dir/$(dirname "${m#*:}")"
      cp "$home_file" "$backup_dir/${m#*:}"
    fi
    mkdir -p "$(dirname "$home_file")"
    cp "$repo_file" "$home_file"
    echo "    PLACED  ~/${m#*:}"
  done
  if [[ -d "$backup_dir" ]]; then
    echo "    (overwritten originals saved in $backup_dir)"
  fi
}

restore_darwin() {
  # Homebrew
  if ! command -v brew >/dev/null 2>&1; then
    echo "==> Installing Homebrew (interactive)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  [[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

  place_files

  echo "==> brew bundle"
  if ! brew bundle --file="$REPO_DIR/brewfile/brewfile"; then
    echo "WARNING: brew bundle had failures (see above) — fix and re-run:"
    echo "         brew bundle --file=\"$REPO_DIR/brewfile/brewfile\""
  fi

  # devbox (installs nix on first use)
  if ! command -v devbox >/dev/null 2>&1; then
    echo "==> Installing devbox"
    curl -fsSL https://get.jetify.com/devbox | bash
  fi

  # nvm (curl installer, not brew)
  if [[ ! -d "$HOME/.nvm" ]]; then
    echo "==> Installing nvm"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
  fi

  cat <<'EOF'

============================================================
 Restore complete. Manual follow-ups:
============================================================
 1. Git identity — create ~/.gitconfig.local (not tracked):
      Work Mac:
        [user]
            name = Zachary Gallagher
            email = zachary.gallagher@people.inc
        [url "git@bitbucket.org:people-inc"]
            insteadOf = https://bitbucket.org/people-inc
      Personal machine: same [user] block with your personal
      email, and no [url] section.
 2. SSH keys:
      ssh-keygen -t ed25519 -C "zachary.gallagher@people.inc"
    then add ~/.ssh/id_ed25519.pub to Bitbucket (work).
    Also create the personal key ~/.ssh/config expects:
      ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_personal
    and add its .pub to your personal GitHub account.
 3. First SSH git pull/clone will ask you to trust the
    bitbucket.org / github.com host fingerprints — verify
    against their published fingerprints and accept.
 4. Hostname:
      sudo scutil --set ComputerName "<name>"
      sudo scutil --set HostName     "<name>"
      sudo scutil --set LocalHostName "<name>"
 5. Karabiner: launch Karabiner-Elements once, grant the
    driver + Input Monitoring permissions in System Settings.
 6. Auth: gcloud auth login / vault login / aws configure.
 7. Devbox/nix: run `devbox global list` once — first run
    installs nix (needs sudo).
 8. Node: `nvm install --lts` in a new shell.
 9. Neovim: open nvim once so lazy.nvim installs plugins.
10. Docker Desktop: launch and sign in.
    Company-managed apps (Sublime Text, etc.): install via
    "People Inc Self Service+" after MDM enrollment — never
    via brew, so Jamf and brew don't fight over updates.
11. Optional drift cron (see README): add with 'crontab -e';
    the first notification may need approving osascript in
    System Settings > Notifications.
12. Open a new terminal so ~/.zprofile and ~/.zshrc load.
============================================================
EOF
}

restore_linux() {
  place_files

  cat <<'EOF'

============================================================
 Configs placed. Manual follow-ups (Linux):
============================================================
 1. Git identity — create ~/.gitconfig.local (not tracked):
      [user]
          name = Zachary Gallagher
          email = <personal email>
 2. Install packages with your distro's package manager
    (no brewfile equivalent is tracked for Linux).
 3. SSH keys:
      ssh-keygen -t ed25519
    then add ~/.ssh/id_ed25519.pub to GitHub; accept host
    fingerprints on first pull.
 4. Node: install nvm, then `nvm install --lts`.
 5. Neovim: open nvim once so lazy.nvim installs plugins.
 6. Open a new terminal so ~/.zshrc loads.
============================================================
EOF
}

restore() {
  echo "==> Restoring configs from $REPO_DIR ($OS)"
  if [[ "$OS" == "Darwin" ]]; then
    restore_darwin
  else
    restore_linux
  fi
}

check() {
  fails=0
  drift=0

  echo "==> Live files vs repo"
  for m in "${MAPPINGS[@]}"; do
    repo_file="$REPO_DIR/${m%%:*}"
    home_file="$HOME/${m#*:}"
    if [[ ! -f "$repo_file" ]]; then
      echo "    [none]  ${m%%:*} not in repo (nothing to restore)"
    elif [[ ! -f "$home_file" ]]; then
      echo "    [DRIFT] ~/${m#*:} missing on this machine"
      drift=$((drift+1))
    elif cmp -s "$repo_file" "$home_file"; then
      echo "    [ok]    ~/${m#*:}"
    else
      echo "    [DRIFT] ~/${m#*:} differs from repo — run './sync.sh backup' to capture"
      drift=$((drift+1))
    fi
  done

  echo "==> Uncommitted / unpushed repo changes"
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
    echo "    [DRIFT] uncommitted changes in repo — commit and push"
    drift=$((drift+1))
  elif [[ -n "$(git -C "$REPO_DIR" log --oneline '@{u}..' 2>/dev/null)" ]]; then
    echo "    [DRIFT] local commits not pushed — push them"
    drift=$((drift+1))
  else
    echo "    [ok]    repo clean and pushed"
  fi

  if [[ "$OS" == "Darwin" ]]; then
    echo "==> Required commands"
    for c in brew git zsh starship nvim fzf zoxide eza bat thefuck devbox; do
      if command -v "$c" >/dev/null 2>&1; then
        echo "    [ok]    $c"
      else
        echo "    [FAIL]  $c not found"
        fails=$((fails+1))
      fi
    done
    if [[ -d "$HOME/.nvm" ]]; then echo "    [ok]    nvm (~/.nvm)"; else echo "    [FAIL]  nvm missing"; fails=$((fails+1)); fi

    echo "==> brew bundle check (unmet may just mean outdated — 'brew bundle' fixes)"
    if brew bundle check --file="$REPO_DIR/brewfile/brewfile" >/dev/null 2>&1; then
      echo "    [ok]    brewfile satisfied"
    else
      echo "    [warn]  brewfile has unmet/outdated entries"
    fi
  fi

  echo "==> Secret scan of tracked repo files"
  secret_hits=0
  for m in "${MAPPINGS[@]}"; do
    repo_file="$REPO_DIR/${m%%:*}"
    if [[ ! -f "$repo_file" ]]; then continue; fi
    if pat="$(has_secret "$repo_file")"; then
      echo "    [FAIL]  ${m%%:*} matches secret pattern '$pat' — remove it before pushing!"
      fails=$((fails+1))
      secret_hits=$((secret_hits+1))
    fi
  done
  if [[ $secret_hits -eq 0 ]]; then
    echo "    [ok]    no tracked file matches a secret pattern"
  fi

  echo "==> Interactive zsh starts cleanly"
  # "can't change option: zle" is normal when zsh runs without a TTY — ignore it
  zsh_err="$(zsh -ic 'exit 0' 2>&1 >/dev/null | grep -v "can't change option: zle" || true)"
  if [[ -z "$zsh_err" ]]; then
    echo "    [ok]    no startup errors"
  else
    echo "    [FAIL]  zsh startup output:"
    echo "$zsh_err" | sed 's/^/            /'
    fails=$((fails+1))
  fi

  scan

  echo
  if [[ $fails -eq 0 && $drift -eq 0 ]]; then
    if [[ $SCAN_WARNINGS -eq 0 ]]; then
      echo "ALL GOOD — repo matches this machine and the environment is healthy."
    else
      echo "ALL GOOD — but $SCAN_WARNINGS untracked ~/.config entr(y/ies) to triage, see [WARN] above."
    fi
  else
    echo "RESULT: $fails failure(s), $drift drift item(s), $SCAN_WARNINGS untracked warning(s) — see above."
    exit 1
  fi
}

undo() {
  sub="${1:-}"
  snaps=()
  for d in "$HOME"/.config-backup-*; do
    if [[ -d "$d" ]]; then snaps+=("$d"); fi
  done
  if [[ ${#snaps[@]} -eq 0 ]]; then
    echo "No snapshots found (~/.config-backup-*). Nothing to undo."
    return 0
  fi

  if [[ "$sub" == "list" ]]; then
    echo "Snapshots (oldest first — 'undo' alone uses the newest):"
    for s in "${snaps[@]}"; do
      echo "  ${s##*.config-backup-}"
      (cd "$s" && find . -type f | sed 's|^\./|      |')
    done
    return 0
  fi

  if [[ -n "$sub" ]]; then
    target="$HOME/.config-backup-$sub"
    if [[ ! -d "$target" ]]; then
      echo "No snapshot '$sub' — see './sync.sh undo list'." >&2
      exit 1
    fi
  else
    target="${snaps[${#snaps[@]}-1]}"
  fi

  echo "==> Undoing from snapshot ${target##*.config-backup-}"
  # Stash the files we're about to overwrite, so undo is itself undoable.
  stash_dir="$HOME/.config-backup-$(date +%Y%m%d-%H%M%S)"
  if [[ -d "$stash_dir" ]]; then stash_dir="${stash_dir}-undo"; fi
  while IFS= read -r rel; do
    rel="${rel#./}"
    src="$target/$rel"
    dst="$HOME/$rel"
    if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
      echo "    same     ~/$rel"
      continue
    fi
    if [[ -f "$dst" ]]; then
      mkdir -p "$stash_dir/$(dirname "$rel")"
      cp "$dst" "$stash_dir/$rel"
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo "    RESTORED ~/$rel"
  done < <(cd "$target" && find . -type f)
  if [[ -d "$stash_dir" ]]; then
    echo "    (replaced versions stashed in $stash_dir — run undo again to redo)"
  fi
}

cron_run() {
  # For crontab use: quiet on success, macOS notification + log on drift.
  # cron's PATH lacks Homebrew, so wire it up first.
  if [[ -x /opt/homebrew/bin/brew ]]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
  log="$HOME/.local/state/configfiles-check.log"
  mkdir -p "$(dirname "$log")"
  if out="$(check 2>&1)"; then
    echo "$(date '+%F %T') OK" >> "$log"
  else
    {
      echo "$(date '+%F %T') DRIFT/FAIL"
      printf '%s\n' "$out"
    } >> "$log"
    if command -v osascript >/dev/null 2>&1; then
      osascript -e 'display notification "Drift or failure detected — run ./sync.sh check" with title "configfiles"' || true
    fi
  fi
}

help() {
  cat <<EOF
sync.sh — keep this configfiles repo and the live machine in sync.
Detects the OS (this run: $OS) and uses the matching file mappings.

USAGE
  ./sync.sh <command>

COMMANDS
  backup    Copy live config files INTO the repo, then show git status.
            Use whenever you've changed a config and want it saved:
            run it, review the diff, commit, push. Never touches
            anything outside the repo.

  restore   Set up this machine FROM the repo. Places every tracked
            config where it belongs (anything it overwrites is saved
            to ~/.config-backup-<timestamp>/). On macOS it also:
            installs Homebrew if missing, runs 'brew bundle', and
            installs devbox and nvm if missing. Ends by printing the
            manual follow-ups (SSH keys, hostname, Karabiner
            permissions, cloud auth, ...). Safe to re-run.

  check     Answer "if I reformatted today, would restore give me this
            machine back?" Verifies: every tracked file matches the
            repo byte-for-byte, the repo is committed AND pushed, the
            required tools are installed, the brewfile is satisfied,
            and interactive zsh starts without errors. Exits 0 only
            when ALL GOOD.

  scan      List everything in ~/.config that is neither tracked by
            MAPPINGS nor intentionally ignored via UNTRACKED_OK, plus
            brew packages installed but missing from the brewfile —
            i.e. things you haven't decided about yet. Track them or
            silence them. Also runs as part of 'check'.

  undo      Roll ~/ back to the newest ~/.config-backup-<ts> snapshot
            (made automatically whenever restore/undo overwrites a
            file). 'undo list' shows snapshots; 'undo <ts>' targets
            one. Undo stashes what it replaces first, so running it
            again redoes — never destructive.

  cron      For crontab: runs 'check' quietly, logs to
            ~/.local/state/configfiles-check.log, and fires a macOS
            notification only when drift/failure is found. Suggested:
              0 10 * * 1  $HOME/code/configfiles/sync.sh cron

  help      This message.

SAFETY
  backup refuses to copy any file matching SECRET_PATTERNS (this repo
  is public); check also fails if a tracked repo file matches.

TRACKED FILES (this OS)
EOF
  for m in "${MAPPINGS[@]}"; do
    printf '  %-28s <-> ~/%s\n' "${m%%:*}" "${m#*:}"
  done
  cat <<'EOF'

TYPICAL FLOWS
  Changed a dotfile:        ./sync.sh backup   then review, commit, push
  Fresh Mac:                git clone <repo>, ./sync.sh restore, follow the checklist
  Peace of mind:            ./sync.sh check

NOT COVERED: SSH keys/credentials, macOS system settings, app sign-ins,
cloned repos under ~/code, nvim plugin versions (lazy-lock is gitignored).
EOF
}

case "${1:-}" in
  backup)       backup ;;
  restore)      restore ;;
  check)        check ;;
  scan)         scan ;;
  undo)         undo "${2:-}" ;;
  cron)         cron_run ;;
  help|-h|--help) help ;;
  *) echo "usage: $0 {backup|restore|check|scan|undo|cron|help}   (see './sync.sh help')" >&2; exit 1 ;;
esac
