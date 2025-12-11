# oh-my-zsh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh

# starship setting
eval "$(starship init zsh)"

# PATHS
export PATH="$PATH:$HOME/.cargo/bin"
export PATH="/opt/homebrew/opt/unzip/bin:$PATH"
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
export PATH="$PATH":"$HOME/.pub-cache/bin"
export PYENV_ROOT="$HOME/.pyenv"
export PATH="/Users/usok/.antigravity/antigravity/bin:$PATH"
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# aliases
alias n="nvim"
alias gotoCode="cd ~/Code"
alias configzsh="nvim ~/.zshrc"
alias confignvim="nvim ~/.config/nvim"
alias lily="$HOME/dotfiles/lily.sh"

# pyenv
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - zsh)"

# bun completions
[ -s "/Users/usok/.bun/_bun" ] && source "/Users/usok/.bun/_bun"

# zoxide
eval "$(zoxide init zsh)"

# google cloud
source "$(brew --prefix)/share/google-cloud-sdk/completion.zsh.inc"

# zsh 설정

# zsh vim 모드
bindkey -v

# hi hello
alias note="n ~/Code/one-folder/projects/Notes"
alias of="cd ~/Code/one-folder/"
alias zshconfig="n ~/.zshrc"

test -e "${HOME}/.iterm2_shell_integration.zsh" && source "${HOME}/.iterm2_shell_integration.zsh"