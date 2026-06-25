# cland-hello

A minimal Java project template that prints "Hello, World!" to stdout.

## Project Layout

```
cland-hello
|
|-- app
|   |-- src
|   |   |-- main
|   |   |   `-- java
|   |   |       `-- org/cland/hello/
|   |   |           `-- ClandHello.java   (application entry point)
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
# Archives: app/build/distributions/cland-hello-*.zip / .tar

./gradlew installDist
# Installed: app/build/install/cland-hello/bin/cland-hello
```

## Technology Stack

| Component | Version |
|-----------|---------|
| Java | 25 |
| Gradle | 9.5 |
| Spotless | 6.25.0 (Google Java Format 1.28.0) |

## License

[MIT](./LICENSE)
