# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0.0] - 2026-09-23

First public release.

### Added
- Auto-OFF of the built-in display on external monitor connect, with a restore procedure and
  self-healing, a per-host verification gate, and `--restore` / `--verify-restore` modes.
- GitHub Actions CI (build, test, package) and a tag-triggered release workflow.
- `--diagnose` (read-only report for bug reports) and `--version` command-line flags.
- Issue templates (bug report, host verification report) and a pull request template.
- `SECURITY.md`.

### Changed
- License wording unified to MIT (removed the "personal use only" notes).
