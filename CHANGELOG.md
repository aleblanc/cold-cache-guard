# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The warning says to press Enter again to confirm: Claude Code puts the held prompt back in the
  input.
- README: screenshots of a real usage spike and of the warning in Claude Code.

## [0.1.0] - 2026-11-10

### Added

- `UserPromptSubmit` gate: holds the prompt once (exit 2) when the session has been idle longer
  than the cache TTL and the context is larger than `COLD_GUARD_MIN_TOKENS`. Re-sending within
  `COLD_GUARD_ACK_SEC` confirms.
- `Stop` hook that records the end of each response and the context size.
- Cache TTL detection from the transcript (1 hour or 5 minutes), with `FORCE_PROMPT_CACHING_5M`
  and `CLAUDE_CODE_PROMPT_CACHE_TTL` as fallbacks.
- `/compact` and `/clear` are never held; a compaction resets the idle time and the context size.
- Sessions resumed right after installation are checked from the transcript timestamps.
- `history.jsonl` event log with 30-day rotation, and the `/cold-cache-guard:stats` command.
- Configuration through `COLD_GUARD_IDLE_MIN`, `COLD_GUARD_MIN_TOKENS`, `COLD_GUARD_ACK_SEC`,
  `COLD_GUARD_DIR`, `COLD_GUARD_HISTORY_DAYS` and `COLD_GUARD_DISABLE`.
- Fail-open behavior: any error lets the prompt through.
- bats test suite and CI on Linux and macOS.

[Unreleased]: https://github.com/aleblanc/cold-cache-guard/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aleblanc/cold-cache-guard/releases/tag/v0.1.0
