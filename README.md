# configfiles

Config backup/restore for the work Mac (with basic Linux support for the
personal machine). One script, three modes.

## Fresh Mac — full restore

1. Clone (the first `git` run prompts the Xcode Command Line Tools install —
   accept it, then rerun):

   ```sh
   git clone https://github.com/ZTGallagher/configfiles.git ~/code/configfiles
   ```

2. Restore (installs Homebrew, places configs, `brew bundle`, devbox, nvm):

   ```sh
   cd ~/code/configfiles && ./sync.sh restore
   ```

3. Do the manual follow-ups the script prints at the end (SSH keys, hostname,
   Karabiner permissions, cloud auth, etc.).

## Day to day

- `./sync.sh backup` — copy live configs into the repo; then review, commit, push.
  Refuses to copy anything matching a secret pattern (this repo is public).
- `./sync.sh check` — verify live files match the repo, everything is pushed,
  required tools exist, no tracked file contains a secret, and zsh starts
  clean. If it says ALL GOOD, a restore from this repo reproduces the setup.
- `./sync.sh scan` — list untracked ~/.config entries and brew packages
  missing from the brewfile, so new tools get triaged instead of forgotten.
- `./sync.sh undo` — roll back the last restore (snapshots are kept in
  `~/.config-backup-<timestamp>/`; `undo list` shows them). Undo stashes what
  it replaces, so it is always reversible.
- Optional drift watch — add to `crontab -e`:

  ```
  0 10 * * 1  $HOME/code/configfiles/sync.sh cron
  ```

  Silent when all good; macOS notification + a line in
  `~/.local/state/configfiles-check.log` when drift is found.

## What is NOT covered

- SSH keys and any credentials (regenerate + re-add per the checklist)
- Git identity — `~/.gitconfig.local` per machine (checklist has the snippets)
- macOS system settings, app sign-ins, browser profiles
- Cloned repos under `~/code` — reclone what you need
- Neovim plugin versions (`lazy-lock.json` is gitignored; lazy.nvim resolves
  fresh on first launch)

## TODO / Someday

- **CI on this repo** — GitHub Action running `shellcheck sync.sh`,
  `bash -n sync.sh`, and a brewfile syntax check, so the restore tooling
  itself can't rot unnoticed.
- **True fresh-machine test** — script a [tart](https://tart.run) macOS VM:
  boot, clone this repo, `./sync.sh restore`, then `./sync.sh check` inside
  it. The only way to exercise the Homebrew/Xcode-CLT bootstrap paths.
- **macOS defaults probe** — a curated script checking the well-known
  preference keys (key repeat, Finder, Dock, screenshots, symbolichotkeys)
  against stock values and reporting what's been changed; the replayable
  `defaults write` file gets authored from that. There is no reliable way to
  diff *all* settings against factory state — best moment to build this is
  right after a reformat, when a true baseline briefly exists.
- **chezmoi** — the graduation path if this script grows too many features.
  Why: templates would replace both the mac/linux zshrc fork and the
  `~/.gitconfig.local` split with one file and `{{ if eq .chezmoi.os }}`
  blocks; built-in `age` encryption would allow tracking private configs
  (ssh hosts, kafkactl) in this same repo; `chezmoi diff`/`apply`/`update`
  are polished versions of backup/restore/check; per-machine facts live in
  `~/.config/chezmoi/chezmoi.toml`. How: the repo layout maps ~1:1
  (`chezmoi init --apply <repo url>` becomes the whole restore path), and
  sync.sh would shrink to just the brew/devbox/nvm bootstrap. Cost: a
  templating DSL and a manual, versus ~400 lines of bash you own outright.
