# Contributing to Timor

Thank you for your interest in contributing to Timor! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

- macOS 26.0+ or iOS 26.0+
- Xcode 26.0+
- A Spotify Developer account and app credentials

### Setting Up Development Environment

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/Timor.git
   cd Timor
   ```
3. Open the project in Xcode:
   ```bash
   open Timor.xcodeproj
   ```
4. Configure your Spotify credentials in the app's Settings

## How to Contribute

### Reporting Bugs

Before creating a bug report:
- Check existing issues to avoid duplicates
- Collect relevant information (macOS/iOS version, steps to reproduce)

When creating a bug report, include:
- A clear, descriptive title
- Steps to reproduce the issue
- Expected vs. actual behavior
- Screenshots if applicable
- Your environment (macOS/iOS version, Xcode version)

### Suggesting Features

Feature requests are welcome! Please:
- Check existing issues first
- Clearly describe the feature and its use case
- Explain why this would benefit users

### Pull Requests

1. **Open an issue first** to discuss the change
2. Fork and create a branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. Make your changes following the code style below
4. Test your changes thoroughly
5. Commit with clear, descriptive messages
6. Push and open a Pull Request

## Code Style

### Swift Guidelines

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use SwiftUI best practices
- Prefer `async/await` over completion handlers
- Use `@MainActor` for UI-related code
- Keep functions focused and reasonably sized

### Architecture

- **SpotifyManager** is the single source of truth for state
- Use `@Published` properties for observable state
- API calls go through **SpotifyWebAPI**
- Sensitive data must use **KeychainManager**

### Documentation

- Add comments for complex logic
- Update documentation if changing public APIs
- Keep README and docs/ updated for user-facing changes

## Testing

Run tests before submitting PRs:

```bash
xcodebuild -project Timor.xcodeproj -scheme Timor -destination 'platform=macOS' test
```

## Project Structure

```
Timor/
├── TimorApp.swift           # App entry point
├── ContentView.swift        # Main coordinator
├── SpotifyManager.swift     # Central state manager
├── SpotifyWebAPI.swift      # OAuth and API calls
├── Views/                   # UI components
├── Models/                  # Data models
└── Utilities/               # Helpers (Keychain, Cache, etc.)
```

## Security

- **Never commit** Spotify credentials or tokens
- Use KeychainManager for all sensitive data
- Report security vulnerabilities privately (see SECURITY.md)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

## Questions?

Open an issue for questions or join the discussion in existing issues.

Thank you for contributing!
