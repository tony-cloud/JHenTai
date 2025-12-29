---
applyTo: "**"
---
# Design Guide for DaliMaster
# Collaboration Notice
To facilitate collaboration, all prompt file must be written in English.

# Code Style
- Follow the Dart and Flutter official style guides.
- Use package imports instead of relative imports to improve code clarity and maintainability.
- Organize imports into three sections: Dart/Flutter SDK imports, third-party package imports, and local project imports. Separate each section with a blank line.
- Name files and classes using lower_snake_case for files and UpperCamelCase for classes.
- Keep line length within 80 characters for better readability.
- Write comments in English to ensure all collaborators can understand them.

# Issue check
- Use `flutter analyze` to get the list of files with issues. Then, for each file, use the problems tool to check for specific problems. Issues check is required after any work with code changes.
- If there are linting issues, fix them according to the suggestions provided by the analyzer. Use 'dart fix' where applicable.

# Test
- Use `flutter test` to run the test suite.
- Aim for high test coverage, especially for critical components.

# API Deprecation Guide
File path: `.github/prompts/deprecated_api_guide.prompt.md`
This file is used for guidance on deprecated APIs. When correcting errors related to deprecated APIs, always check the latest documentation online first. Then, document the API changes and important notes in this file for future reference.
