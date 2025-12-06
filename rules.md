# Claude Nights Watch Safety Rules

## Directory Restrictions

ONLY work within the project folder:
- `/Users/whit3rabbit/Documents/GitHub/zigk/`

## Allowed Operations

1. **File Operations** - Only within project directory:
   - Read files in `src/`, `tests/`, `specs/`, `.specify/`
   - Write/edit files in `src/`, `tests/`
   - Read configuration files (CLAUDE.md, build.zig, etc.)

2. **Commands** - Only project-related:
   - `zig build` and `zig test`
   - `git status`, `git diff`, `git add`, `git commit`
   - Speckit slash commands

## Forbidden Operations

1. **Directory Access**:
   - DO NOT access files outside `/Users/whit3rabbit/Documents/GitHub/zigk/`
   - DO NOT modify system files
   - DO NOT access other repositories or projects

2. **Destructive Actions**:
   - DO NOT run `rm -rf` on directories
   - DO NOT force push to git
   - DO NOT modify `.git/` internals

3. **Network Operations**:
   - DO NOT make external API calls (except documentation lookups)
   - DO NOT download external dependencies without explicit spec requirement

## Review Before Commit

Before any git commit:
- Verify all changes are within project scope
- Ensure tests exist for new code
- Confirm code follows spec requirements
