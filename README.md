# devpod-gh

Quality of life plugin.

I like vibe coding and `yolo` mode, this is to make using local devcontainers easier and more seamless for "safer" yolo.

I get GitHub Copilot through work, so getting "automatic" sign in to me is important. I have been learning neovim (and am use to vscode), so auto port forwarding.

This is a simple function wrapper around [devpod](https://github.com/loft-sh/devpod) which checks for `devpod` and [github cli](https://cli.github.com/).

## Dependencies

- [devpod](https://github.com/loft-sh/devpod) - Development container management
- [github cli](https://cli.github.com/) - GitHub authentication and token generation
- [gum](https://github.com/charmbracelet/gum) - Interactive workspace selection
- [jq](https://jqlang.github.io/jq/) - JSON processing for port monitoring
- `ssh`/`scp` - Remote connection and file transfer
- `stdbuf` - Unbuffered output handling for port monitoring

## Installation

### Oh My Zsh

Clone this repository into your Oh My Zsh custom plugins directory:

```zsh
git clone https://github.com/scaryrawr/devpod-gh.zsh ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/devpod-gh
```

Then add `devpod-gh` to your plugins array in `~/.zshrc`:

```zsh
plugins=(... devpod-gh)
```

### Antidote

```
antidote install scaryrawr/devpod-gh.zsh
```

## Configuration

### SSH ControlMaster (Required for optimal performance)

Configure SSH ControlMaster in your `~/.ssh/config` for optimal port forwarding performance:

```ssh-config
Host *
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
```

This enables connection multiplexing, which allows multiple SSH connections to share a single network connection. This significantly speeds up establishing new port forwards by avoiding repeated SSH handshakes and authentication.

## Features

### Automatic GitHub Token Injection

When you ssh into a devpod using `devpod ssh`:

```zsh
devpod ssh
```

The wrapper automatically injects environment variables:

- **GH_TOKEN**: Using `gh auth token`
- **GH_COPILOT_TOKEN**: Automatically extracted from `~/.config/github-copilot/apps.json` if available

```zsh
devpod ssh --set-env GH_TOKEN=`gh auth token` --set-env GH_COPILOT_TOKEN=<token>
```

This enables things like [github copilot cli](https://github.com/features/copilot/cli/) and [github cli](https://github.com/devcontainers/features/tree/main/src/github-cli) to just work... automagically, in devpods.

### Automatic Port Forwarding

The plugin automatically monitors and forwards ports that are bound inside your devpod workspace. When an application starts listening on a port inside the devpod, it will be automatically forwarded to your local machine on the same port.

This uses a background port monitoring process that watches for port binding events and establishes SSH tunnels as needed. The port forwarding is cleaned up automatically when you disconnect.

### Automatic Reverse Port Forwarding (Self-hosted LLMs)

The plugin automatically detects and reverse-forwards local LLM services to your devpod:

- **Port 1234**: LM Studio
- **Port 11434**: Ollama

When these services are running locally, they become accessible inside your devpod, allowing you to use self-hosted AI models in your remote development environment.
