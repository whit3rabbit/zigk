# Claude Nights Watch Task

## Objective
Execute the speckit implementation workflow to generate code and tests based on the current feature specification.

## Instructions

1. Always use Zig skill when writing Zig code and work on specs in the `specs/` directory marking them off as you go.
2. For each task in the implementation:
   - Write the required source code following the spec
   - Create corresponding test files in the `tests/` directory
   - Ensure tests validate the specification requirements
3. Adhere strictly to the feature specification in `specs/`
4. Follow the coding style defined in CLAUDE.md (Zig conventions, HAL barrier, etc.)
5. Mark tasks as completed as you progress

## Constraints
- All code must match the architecture defined in the plan
- Tests must cover the acceptance criteria from the spec
- Use the Zig skill when writing Zig code
- Follow constitutional enforcements (HAL barrier, memory hygiene, Linux compatibility)

## Success Criteria
- All tasks from tasks.md are completed
- Test files exist for implemented functionality
- Code compiles without errors
- Tests pass
