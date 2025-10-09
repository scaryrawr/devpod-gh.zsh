#!/usr/bin/env zsh

if (( $+commands[devpod] )) && (( $+commands[gh] )); then
  devpod() {
    local args=("$@")
    if [[ " ${args[*]} " == *" ssh "* ]]; then
      args+=(--set-env)
      args+=(GH_TOKEN=$(gh auth token))
    fi
    
    command devpod "${args[@]}"
  }
fi
