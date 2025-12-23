---
applyTo: "**"
---
# Design Guide for DaliMaster
# Collaboration Notice
To facilitate collaboration, the prompt file must be written in English.

# Issue check
- Use `flutter analyze` to get the list of files with issues. Then, for each file, use the problems tool to check for specific problems. Issues check is required after any work with code changes.
- If there are linting issues, fix them according to the suggestions provided by the analyzer. Use 'dart fix' where applicable.

# Test
- Use `flutter test` to run the test suite.
- Aim for high test coverage, especially for critical components.

# API Deprecation Guide
File path: `.github/prompts/deprecated_api_guide.prompt.md`
This file is used for guidance on deprecated APIs. When correcting errors related to deprecated APIs, always check the latest documentation online first. Then, document the API changes and important notes in this file for future reference.
