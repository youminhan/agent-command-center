# Contributing

Thanks for helping improve Agent Command Center. Bug reports, ideas and pull requests are all welcome.

## Ways to help

- **Report a bug** or **suggest a feature** with an [issue](https://github.com/youminhan/agent-command-center/issues/new/choose).
- **Fix something.** Issues labelled `good first issue` are a good start.
- **Improve the docs**, including this file.

## Set up

You need macOS 13 or later, tmux, Python 3 and the Xcode Command Line Tools.

```sh
git clone https://github.com/youminhan/agent-command-center.git
cd agent-command-center
python3 app.py            # backend + UI at http://127.0.0.1:8765
```

Edit `ui.html` or `app.py` and reload the page. To build and run the Mac app:

```sh
cd macapp && ./build.sh --install
```

## Project layout

| Path | What it is |
|---|---|
| `app.py` | Backend: tmux, Copilot session files, snapshots, clean-up, JSON API. Standard library only. |
| `ui.html` | The whole interface. No build step or framework. |
| `macapp/main.swift` | Native app: window, menu bar, terminal integration, LaunchAgent, login item. |
| `macapp/logo.swift` | The logo geometry, shared by the app icon and the menu-bar icon. |
| `scripts/` | Demo data and README screenshots. |

## Guidelines

- **Keep dependencies at zero.** Python standard library and system frameworks only.
- **Stay local.** No network calls, no telemetry. The server listens on `127.0.0.1` only.
- **Never lose user data.** Anything destructive needs a confirmation or goes to the Trash.
- **Match the UI conventions** in `ui.html`: role-based color tokens, real buttons, labels on icon-only buttons, and motion that respects Reduce Motion.
- **Test what you change.** Run the backend against a throwaway tmux server and data folder:

  ```sh
  export TMUX_TMPDIR=$(mktemp -d) TMUX_MANAGER_HOME=$(mktemp -d) ACC_COPILOT_HOME=$(mktemp -d)
  python3 app.py --port 8799
  ```
- If the UI changes, regenerate screenshots with `scripts/screenshots.sh`.
- Add a line to [CHANGELOG.md](CHANGELOG.md) under **Unreleased** for anything users will notice.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep each pull request to one focused change, with a clear description and screenshots for UI changes.
3. Make sure the app builds with `macapp/build.sh` and the page has no JavaScript errors.

## Conduct

Be kind and assume good intent. This project follows the
[Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/).
Report unacceptable behavior by opening a private
[security advisory](https://github.com/youminhan/agent-command-center/security/advisories/new) or contacting the maintainer.
