# Contributing to MacSteam

## Code of Conduct

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to uphold it.

## Getting Started

1. Fork the repository
2. Create a feature branch (`feat/your-feature-name`)
3. Commit your changes
4. Push to your fork
5. Open a Pull Request

## Development Requirements

- macOS (Apple Silicon)
- Xcode 16+
- Swift 6.0+

## Before Submitting

- Run `swift build` and `swift test`
- Run `scripts/public-audit.sh`
- Ensure no real paths, credentials, or personal information are present
- Ensure no proprietary binaries or third-party assets are included

## Code Style

- Follow Swift API Design Guidelines
- Use `// MARK:` for section organization
- Add documentation comments for public APIs
- Keep functions focused and small
- Use protocol-oriented design

## Commits

- Use conventional commit prefixes: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `ci:`
- Keep commits atomic and focused
- Do not include credentials, tokens, or personal paths

## Pull Requests

- Title should describe the change (e.g., `feat: add CrossOver runtime detection`)
- Include a summary of changes
- Reference related issues
- Mark as Draft if not ready for review

## Licensing

By contributing, you agree that your contributions will be licensed under GPL-3.0-or-later.
