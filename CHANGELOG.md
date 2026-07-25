# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-26

### Added

- Initial public bootstrap
- Branding isolation via `AppBrand` enum
- `CompatibilityRuntime` protocol with `CrossOverRuntime` and `MockRuntime`
- `GameRecipe` and `RecipeLoader` with validation
- `RuntimeLocator` for bundle detection
- `SteamDetector` for macOS vs Windows Steam distinction
- `ProcessRunner` with safety guards
- `PathRedactor` for privacy-safe logging
- `DiagnosticsStore` for local-only diagnostics
- `GameManager` driving state machine
- CloverPit recipe (`Resources/Recipes/cloverpit.json`)
- Single-screen SwiftUI launcher
- Unit tests for all core components
- GitHub Actions CI (build, test, audit)
- Privacy, security, and contribution documentation
