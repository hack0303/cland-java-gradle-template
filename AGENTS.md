# cland-plantuml — Quickstart Guide

**cland-plantuml** is a minimal Java project template — currently prints "Hello, World!" to stdout.

## Repository Layout

| Path | Description |
|------|-------------|
| `app/src/main/java/org/cland/plantuml/` | Main source code |
| `app/build.gradle` | Project build configuration |

### Source Files

| File | Purpose |
|------|---------|
| `ClandPlantuml.java` | Application entry point with `main()` method |

## Prerequisites

- JDK 25+ (temurin or equivalent)
- Gradle 9.5 (wrapper provided)

## Building and Running

### Build the project
```bash
./gradlew clean build
```

### Run the application
```bash
./gradlew :app:run
```

Expected output:
```
Hello, World!
```

## Commit Messages and Pull Requests

- Follow the [Chris Beams](http://chris.beams.io/posts/git-commit/) style for commit messages.
- Every pull request should answer:
  - **What changed?**
  - **Why?**
  - **Breaking changes?**
  - **Related TODO items** (see `TODO-*.md` files in project root)
- Comments should be complete sentences and end with a period.

## Additional Resources

- [README.md](./README.md) — Project overview
