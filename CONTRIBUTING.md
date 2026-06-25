# Contributing to cland-plantuml

This doc is intended for contributors to **cland-plantuml** (hopefully that's you!)

## Development Environment

- **Java 25+** is required to run Gradle, compile the project, and run all tests.
- **Gradle 9.5** (wrapper provided via `./gradlew`).
- **Git** with proper commit message conventions.

## Build

```bash
./gradlew clean build
```

This compiles the application.

## Running the Application

```bash
# Via Gradle
./gradlew :app:run

# From installed distribution
./gradlew installDist
./app/build/install/cland-plantuml/bin/cland-plantuml
```

## Commit Messages

We follow the [Chris Beams](http://chris.beams.io/posts/git-commit/) guide to writing git commit messages:

- Separate subject from body with a blank line
- Limit subject line to 50 characters
- Capitalize the subject line
- Do not end the subject line with a period
- Use the imperative mood in the subject line
- Wrap the body at 72 characters
- Use the body to explain *what* and *why* (not *how*)

### Commit message structure:
```
<scope>: <short description>

More detailed explanation wrapping at 72 characters.

Closes #123
```

### Recommended prefixes:
| Prefix | Scope |
|--------|-------|
| `app` | Application entry point and core logic |
| `build` | Gradle/build config, dependencies |
| `docs` | Documentation only |

## Pull Request Checklist

Before submitting a PR, ensure:

- [ ] `./gradlew check` passes (all tests succeed)
- [ ] Documentation (AGENTS.md, README.md) is updated for user-facing changes

## Pull Request Description

Every pull request should answer:

- **What changed?** — Summary of the changes
- **Why?** — Motivation and context
- **Breaking changes?** — Yes/No, with migration notes if applicable
- **Related issues/TODOs** — Links to relevant issue numbers

## Code Style

- Use **Java 25** language features where appropriate (records, sealed classes, pattern matching, text blocks, etc.)
- Keep classes focused and single-responsibility

## Getting Help

- See the [AGENTS.md](./AGENTS.md) for a quickstart overview
- See [README.md](./README.md) for project overview
