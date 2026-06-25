# cland-plantuml

A minimal Java project template that prints "Hello, World!" to stdout.

## Project Layout

```
cland-plantuml
|
|-- app
|   |-- src
|   |   |-- main
|   |   |   `-- java
|   |   |       `-- org/cland/plantuml/
|   |   |           `-- ClandPlantuml.java   (application entry point)
|   |   `-- build.gradle
|
|-- .gitignore
|-- LICENSE
|-- AGENTS.md
|-- CONTRIBUTING.md
|-- README.md
|-- gradlew
|-- gradlew.bat
`-- settings.gradle
```

## Prerequisites

- JDK 25+ (temurin or equivalent)
- Gradle 9.5 (wrapper provided)

## Build

```bash
./gradlew clean build
```

## Code Formatting

Code formatting is enforced by [Spotless](https://github.com/diffplug/spotless) with **Google Java Format** (AOSP variant). Formatting runs automatically during `build`, but you can also run it explicitly:

```bash
# Apply formatting
./gradlew spotlessApply

# Check formatting (without making changes)
./gradlew spotlessCheck
```

## Run the Application

```bash
./gradlew :app:run
```

Expected output:
```
Hello, World!
```

## Building Distribution Archives

```bash
./gradlew assembleDist
# Archives: app/build/distributions/cland-plantuml-*.zip / .tar

./gradlew installDist
# Installed: app/build/install/cland-plantuml/bin/cland-plantuml
```

## Technology Stack

| Component | Version |
|-----------|---------|
| Java | 25 |
| Gradle | 9.5 |
| Spotless | 6.25.0 (Google Java Format 1.28.0) |

## License

[MIT](./LICENSE)
