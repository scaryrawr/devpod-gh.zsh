#!/usr/bin/env zsh

# Internal function to manage automatic port forwarding for a devpod workspace (independent of gum)
_devpod-portforward() {
  local selected_space="$1"
  if [[ -z "$selected_space" ]]; then
    echo "Usage: devpod-portforward <workspace-name>" >&2
    return 1
  fi
  
  # Ensure workspace is up (with explicit output handling)
  echo "[devpod-gh] Ensuring workspace is up..." >&2
  command devpod up --open-ide false "$selected_space" >/dev/null 2>&1
  
  # Copy monitoring script
  local script_path="${${(%):-%x}:A:h}/portmonitor.sh"
  local devpod_host="${selected_space}.devpod"
  echo "[devpod-gh] Copying portmonitor script..." >&2
  scp -q "$script_path" "${devpod_host}:~/" 2>/dev/null
  
  typeset -gA DEVPOD_PORT_FORWARD_PIDS
  cleanup_port_forwarding() {
    for pid in ${DEVPOD_PORT_FORWARD_PIDS[@]}; do
      kill "$pid" 2>/dev/null
    done
  }
  trap cleanup_port_forwarding EXIT
  
  echo "[devpod-gh] Port monitoring started for workspace: ${selected_space}" >&2
  echo "[devpod-gh] Starting SSH monitoring loop..." >&2
  
  # Use unbuffered output and explicit exec to avoid subshell issues
  # Redirect stdin from /dev/null to prevent SSH from waiting for input
  exec 3< <(command devpod ssh --command 'exec stdbuf -oL bash ~/portmonitor.sh' "$selected_space" </dev/null 2>&1)
  while IFS= read -r line <&3; do
    echo "[devpod-gh] Received: $line" >&2
    local event_type=$(echo "$line" | jq -r '.type // empty')
    if [[ "$event_type" == "port" ]]; then
      local action=$(echo "$line" | jq -r '.action // empty')
      local port=$(echo "$line" | jq -r '.port // empty')
      local protocol=$(echo "$line" | jq -r '.protocol // empty')
      if [[ "$action" == "bound" && -n "$port" ]]; then
        command devpod ssh -L "${port}" "$selected_space" </dev/null >/dev/null 2>&1 &
        local forward_pid=$!
        disown
        DEVPOD_PORT_FORWARD_PIDS["${port}"]=$forward_pid
        echo "[devpod-gh] Port forwarding started: ${port} (PID: ${forward_pid})" >&2
      elif [[ "$action" == "unbound" && -n "$port" ]]; then
        local forward_pid=${DEVPOD_PORT_FORWARD_PIDS["${port}"]}
        if [[ -n "$forward_pid" ]]; then
          kill "$forward_pid" 2>/dev/null
          unset "DEVPOD_PORT_FORWARD_PIDS[${port}]"
          echo "[devpod-gh] Port forwarding stopped: ${port}" >&2
        fi
      fi
    fi
  done
  exec 3<&-
}

devpod() {
  local args=("$@")
  
  # Skip gum selection if --help or -h is present, or non-interactive SSH flags like -L, -R
  if [[ " ${args[*]} " == *" --help "* ]] || [[ " ${args[*]} " == *" -h "* ]] || \
     [[ " ${args[*]} " == *" -L "* ]] || [[ " ${args[*]} " == *" --forward-local "* ]] || \
     [[ " ${args[*]} " == *" -R "* ]] || [[ " ${args[*]} " == *" --forward-remote "* ]] || \
     [[ " ${args[*]} " == *" -D "* ]] || [[ " ${args[*]} " == *" --forward-socks "* ]] || \
     [[ " ${args[*]} " == *" -W "* ]] || [[ " ${args[*]} " == *" --forward-stdio "* ]] || \
     [[ " ${args[*]} " == *" --command "* ]]; then
    command devpod "${args[@]}"
    return
  fi
  
  # Skip gum selection if not ssh command
  if [[ " ${args[*]} " != *" ssh "* ]]; then
    command devpod "${args[@]}"
    return
  fi
  
  local spaces=`command devpod ls --provider docker --output json | jq -r '.[].id'`
  
  args+=(--set-env)
  args+=(GH_TOKEN=$(gh auth token))
  
  # Check if any space is already included in args
  local selected_space=""
  local space_found=0
  for space in ${(f)spaces}; do
    if [[ " ${args[*]} " == *" $space "* ]]; then
      space_found=1
      selected_space="$space"
      break
    fi
  done
  
  # If no space found in args, prompt with gum
  if [[ $space_found -eq 0 && -n "$spaces" ]]; then
    selected_space=$(echo "$spaces" | gum choose --header 'Please select a workspace from the list below')
    if [[ -n "$selected_space" ]]; then
      args+=("$selected_space")
    else
      return
    fi
  fi
  
  # Copy and start portmonitor.sh on the devpod if we have a selected_space
  if [[ -n "$selected_space" ]]; then
    local _pf_log=$(mktemp -t devpod-portforward.${selected_space}.XXXXXX.log)
    _devpod-portforward "$selected_space" >"$_pf_log" 2>&1 &!
    echo "[devpod-gh] Port forwarding monitor started in background (log: $_pf_log)" >&2
  fi
  
  command devpod "${args[@]}"
}
