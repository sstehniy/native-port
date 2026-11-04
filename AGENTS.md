# Order of the Sinking Star native port

- Keep the implementation small and preserve gameplay, graphics and save formats.
- The active implementation is `recomp/`, `runtime/` and `d3d12-metal/`.
- Read `README.md` for the build, architecture and usage instructions.
- Never commit game files, extracted shaders, generated game code, binaries, captures or saves.
  Generate them from the user's own game under ignored `build/`.
- Never modify the original installation or personal saves. Use a private profile for tests.
- Keep existing save paths, preference keys and the bundle identifier stable.
- Do not launch the game, push commits or use subagents unless explicitly requested.
- Make focused changes and run the relevant checks. State what remains untested.
- Run `python3 tools/recomp_compdb.py` after adding/removing indexed C, C++ or Objective-C++ files,
  or changing compilation settings. `compile_commands.json` stays local and ignored.
- Keep dependency licenses and attribution. Do not redistribute the game's assets.
- Remove task-created temporary files and processes; preserve current local builds, dependencies and saves.
- Commit completed, verified changes with a focused Conventional Commits message.
