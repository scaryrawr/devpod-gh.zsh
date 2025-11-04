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
  
  # Ensure workspace is up
  echo "[devpod-gh] Ensuring workspace is up..." >&2
  command devpod up --open-ide false "$selected_space" >/dev/null 2>&1
  
  local devpod_host="${selected_space}.devpod"
  typeset -gA DEVPOD_REVERSE_PORT_PIDS
  
  # Check if port 1234 is listening locally (LM Studio)
  if lsof -iTCP:1234 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "[devpod-gh] Reverse forwarding lm studio..." >&2
    ssh -R 1234:localhost:1234 "$devpod_host" -N </dev/null >/dev/null 2>&1 &
    DEVPOD_REVERSE_PORT_PIDS[1234]=$!
    echo "[devpod-gh] Reverse proxy started for port 1234 (PID: ${DEVPOD_REVERSE_PORT_PIDS[1234]})" >&2
  fi
  
  # Check if port 11434 is listening locally (Ollama)
  if lsof -iTCP:11434 -sTCP:LISTEN -t >/dev/null 2>&1; then
    echo "[devpod-gh] Reverse forwarding ollama..." >&2
    ssh -R 11434:localhost:11434 "$devpod_host" -N </dev/null >/dev/null 2>&1 &
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
  ssh "$devpod_host" "cat > ~/portmonitor.sh" < "$script_path" 2>/dev/null
  
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
  ssh "$devpod_host" 'exec stdbuf -oL bash ~/portmonitor.sh' </dev/null 2>&1 | while IFS= read -r line; do
    echo "[devpod-gh] Received: $line" >&2
    local event_type=$(echo "$line" | jq -r '.type // empty')
    if [[ "$event_type" == "port" ]]; then
      local action=$(echo "$line" | jq -r '.action // empty')
      local port=$(echo "$line" | jq -r '.port // empty')
      if [[ "$action" == "bound" && -n "$port" ]]; then
        ssh -L "${port}:localhost:${port}" "$devpod_host" -N </dev/null >/dev/null 2>&1 &
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
  
  # Add GitHub Copilot token if available
  local config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  if [[ -f "$config_home/github-copilot/apps.json" ]]; then
    local copilot_token=$(jq -r '."github.com:Iv1.b507a08c87ecfe98".oauth_token // empty' "$config_home/github-copilot/apps.json" 2>/dev/null)
    if [[ -n "$copilot_token" ]]; then
      args+=(--set-env GH_COPILOT_TOKEN="$copilot_token")
    fi
  fi
  
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
    local _rf_log=$(mktemp -t devpod-reverseforward.${selected_space}.XXXXXX.log)
    local devpod_host="${selected_space}.devpod"
    
    # Start SSH ControlMaster for multiplexing
    ssh -MNf "$devpod_host" 2>/dev/null
    
    echo "[devpod-gh] Starting port forwarding monitor (log: $_pf_log)" >&2
    echo "[devpod-gh] Starting reverse forwarding monitor (log: $_rf_log)" >&2
    
    _devpod-portforward "$selected_space" >"$_pf_log" 2>&1 &
    local _pf_pid=$!
    
    # Start reverse port forwarding
    _devpod-portreverse "$selected_space" >"$_rf_log" 2>&1 &
    local _rf_pid=$!
    
    cleanup_devpod_session() {
      # Cleanup port forwarding process and all its children
      if [[ -n "$_pf_pid" ]]; then
        kill -- -"$_pf_pid" 2>/dev/null
        wait "$_pf_pid" 2>/dev/null
      fi
      
      # Cleanup reverse port forwarding process
      if [[ -n "$_rf_pid" ]]; then
        kill -- -"$_rf_pid" 2>/dev/null
        wait "$_rf_pid" 2>/dev/null
      fi
      
      # Cleanup reverse port forwarding PIDs
      if [[ -n "${DEVPOD_REVERSE_PORT_PIDS}" ]]; then
        for pid in ${DEVPOD_REVERSE_PORT_PIDS[@]}; do
          _kill_process "$pid"
        done
        DEVPOD_REVERSE_PORT_PIDS=()
      fi
      
      # Cleanup any remaining background jobs
      local bg_jobs=(${${(v)jobstates##*:*:}%=*})
      for job_pid in $bg_jobs; do
        kill "$job_pid" 2>/dev/null
      done
      
      # Exit SSH ControlMaster connection
      if [[ -n "$selected_space" ]]; then
        ssh -O exit "${selected_space}.devpod" 2>/dev/null
      fi
      
      # Remove temp log files
      [[ -f "$_pf_log" ]] && rm -f "$_pf_log"
      [[ -f "$_rf_log" ]] && rm -f "$_rf_log"
    }
    
    trap cleanup_devpod_session EXIT INT TERM
  fi
  
  command devpod "${args[@]}"
  
  # Ensure cleanup runs after SSH session exits
  cleanup_devpod_session
}
