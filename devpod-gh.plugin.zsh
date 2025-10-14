#!/usr/bin/env zsh

# Helper to kill a process gracefully then forcefully if needed
_kill_process() {
  local pid="$1"
  [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null && return
  kill "$pid" 2>/dev/null
  sleep 0.1
  kill -9 "$pid" 2>/dev/null
}

_devpod-portreverse() {
  local selected_space="$1"
  if [[ -z "$selected_space" ]]; then
    echo "Usage: _devpod-portreverse <workspace-name>" >&2
    return 1
  fi
  
  typeset -gA DEVPOD_REVERSE_PORT_PIDS
  
  # Check if port 1234 is listening locally
  if lsof -iTCP:1234 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "[devpod-gh] Local port 1234 is listening, setting up reverse proxy..." >&2
    command devpod ssh -R 1234 "$selected_space" </dev/null >/dev/null 2>&1 &
    DEVPOD_REVERSE_PORT_PIDS[1234]=$!
    echo "[devpod-gh] Reverse proxy started for port 1234 (PID: ${DEVPOD_REVERSE_PORT_PIDS[1234]})" >&2
  fi
  
  # Check if port 11434 is listening locally
  if lsof -iTCP:11434 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "[devpod-gh] Local port 11434 is listening, setting up reverse proxy..." >&2
    command devpod ssh -R 11434 "$selected_space" </dev/null >/dev/null 2>&1 &
    DEVPOD_REVERSE_PORT_PIDS[11434]=$!
    echo "[devpod-gh] Reverse proxy started for port 11434 (PID: ${DEVPOD_REVERSE_PORT_PIDS[11434]})" >&2
  fi
}

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
  local ssh_monitor_pid=""
  
  cleanup_port_forwarding() {
    for pid in ${DEVPOD_PORT_FORWARD_PIDS[@]}; do
      _kill_process "$pid"
    done
    DEVPOD_PORT_FORWARD_PIDS=()
    
    [[ -n "$ssh_monitor_pid" ]] && kill -- -"$ssh_monitor_pid" 2>/dev/null
    exec 3<&- 2>/dev/null
  }
  trap cleanup_port_forwarding EXIT INT TERM
  
  echo "[devpod-gh] Port monitoring started for workspace: ${selected_space}" >&2
  echo "[devpod-gh] Starting SSH monitoring loop..." >&2
  
  # Start SSH monitoring in background and track its PID
  command devpod ssh --command 'exec stdbuf -oL bash ~/portmonitor.sh' "$selected_space" </dev/null 2>&1 | while IFS= read -r line; do
    echo "[devpod-gh] Received: $line" >&2
    local event_type=$(echo "$line" | jq -r '.type // empty')
    if [[ "$event_type" == "port" ]]; then
      local action=$(echo "$line" | jq -r '.action // empty')
      local port=$(echo "$line" | jq -r '.port // empty')
      if [[ "$action" == "bound" && -n "$port" ]]; then
        command devpod ssh -L "${port}" "$selected_space" </dev/null >/dev/null 2>&1 &
        local forward_pid=$!
        DEVPOD_PORT_FORWARD_PIDS["${port}"]=$forward_pid
        echo "[devpod-gh] Port forwarding started: ${port} (PID: ${forward_pid})" >&2
      elif [[ "$action" == "unbound" && -n "$port" ]]; then
        local forward_pid=${DEVPOD_PORT_FORWARD_PIDS["${port}"]}
        if [[ -n "$forward_pid" ]]; then
          _kill_process "$forward_pid"
          unset "DEVPOD_PORT_FORWARD_PIDS[${port}]"
          echo "[devpod-gh] Port forwarding stopped: ${port}" >&2
        fi
      fi
    fi
  done &
  ssh_monitor_pid=$!
  
  wait "$ssh_monitor_pid" 2>/dev/null
}

devpod() {
  local args=("$@")
  local args_str=" ${args[*]} "
  
  # Skip wrapper for help, non-interactive SSH flags, or non-ssh commands
  if [[ "$args_str" =~ " (-h|--help|--command|-[LRDW]|--forward-(local|remote|socks|stdio)) " ]] || \
     [[ "$args_str" != *" ssh "* ]]; then
    command devpod "${args[@]}"
    return
  fi
  
  local spaces=$(command devpod ls --provider docker --output json | jq -r '.[].id')
  args+=(--set-env GH_TOKEN=$(gh auth token))
  
  # Check if workspace already specified in args
  local selected_space=""
  for space in ${(f)spaces}; do
    if [[ "$args_str" == *" $space "* ]]; then
      selected_space="$space"
      break
    fi
  done
  
  # Prompt with gum if no workspace found
  if [[ -z "$selected_space" && -n "$spaces" ]]; then
    selected_space=$(echo "$spaces" | gum choose --header 'Please select a workspace from the list below')
    [[ -n "$selected_space" ]] && args+=("$selected_space") || return
  fi
  
  # Start port forwarding if we have a workspace
  if [[ -n "$selected_space" ]]; then
    local _pf_log=$(mktemp -t devpod-portforward.${selected_space}.XXXXXX.log)
    _devpod-portforward "$selected_space" >"$_pf_log" 2>&1 &
    local _pf_pid=$!
    
    # Start reverse port forwarding
    _devpod-portreverse "$selected_space"
    
    cleanup_devpod_session() {
      # Cleanup port forwarding
      [[ -n "$_pf_pid" ]] && kill "$_pf_pid" 2>/dev/null
      
      # Cleanup reverse port forwarding
      if [[ -n "${DEVPOD_REVERSE_PORT_PIDS}" ]]; then
        for pid in ${DEVPOD_REVERSE_PORT_PIDS[@]}; do
          _kill_process "$pid"
        done
        DEVPOD_REVERSE_PORT_PIDS=()
      fi
    }
    
    trap cleanup_devpod_session EXIT INT TERM
    echo "[devpod-gh] Port forwarding monitor started in background (PID: $_pf_pid, log: $_pf_log)" >&2
  fi
  
  command devpod "${args[@]}"
}
