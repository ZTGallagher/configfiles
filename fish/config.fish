# --- Homebrew Path ---
eval (/home/linuxbrew/.linuxbrew/bin/brew shellenv)

# --- General Aliases ---
alias k 'kubectl'
alias t 'tofu'
alias nv 'nvim'

# --- Environment Variables ---
set -x GPG_TTY (tty)
set -x EDITOR (which nvim)
set -x BAT_THEME "Dracula"
set -x STARSHIP_CONFIG ~/.config/starship/starship.toml

# --- fzf ---
eval (fzf --fish)

# --- eza ---
alias ls "eza --color=always --icons=auto --git"
alias lt "eza -l --color=always -snew --icons=auto --git"

# --- zoxide ---
eval (zoxide init fish)
alias cd 'z'

# --- Starship Prompt ---
eval (starship init fish)

