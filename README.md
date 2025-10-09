# devpod-gh

Quality of life plugin.

This is a simple function wrapper around [devpod](https://github.com/loft-sh/devpod) which checks for `devpod` and [github cli](https://cli.github.com/).

What it does, is simply, generate a token when you ssh into a devpod:

```zsh
devpod ssh
```

It is equivalent to:

```zsh
devpod ssh --set-env GH_TOKEN=`gh auth token`
```

This enables things like [github copilot cli](https://github.com/features/copilot/cli/) to just work... automagically, in devpods.

It magically enables the [github cli](https://github.com/devcontainers/features/tree/main/src/github-cli) feature.

I think you can do something similar with the `remoteEnv` in [devcontainer.json](https://containers.dev/implementors/json_reference/), but if you have multiple GitHub accounts, you need to juggle the environment variable anyways before calling devpod I believe.
