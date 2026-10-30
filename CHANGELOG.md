# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.0] - 2026-10-30

### Added
- Overview page with metrics, tmux sessions, recent Copilot sessions, memory by session, suggestions and auto-save status.
- Command palette (<kbd>⌘K</kbd>) and shortcuts for every page (<kbd>⌘1</kbd>–<kbd>⌘6</kbd>).
- Side panel with a Copilot session's summary, next steps, PRs, files and actions.
- New logo, app icon and menu-bar icon.
- `scripts/screenshots.sh` to regenerate README screenshots from demo data.

### Changed
- Redesigned interface: sidebar navigation, translucent macOS sidebar, refined light and dark themes.
- Text and buttons meet WCAG AA contrast; full keyboard and screen-reader support; respects Reduce Motion.

## [1.0.0] - 2026-10-30

### Added
- Background auto-save of every tmux session, with restore after a restart.
- Copilot CLI sessions: running and saved, memory use, summaries, Resume, Resume in tmux, Move to tmux, Stop and Delete.
- Clean up rules for old snapshots, idle tmux sessions and inactive Copilot sessions, with a preview.
- Native Dock and menu-bar app, universal for Apple silicon and Intel.

[Unreleased]: https://github.com/youminhan/agent-command-center/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/youminhan/agent-command-center/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/youminhan/agent-command-center/releases/tag/v1.0.0
