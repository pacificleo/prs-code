/// Content for the CherryLily CLI skill installed into coding agent configs.
nonisolated enum CLISkillContent {
  static let skillName = "cherrylily-cli"

  static let description =
    "Control CherryLily from the terminal."
    + " Use when running cherrylily CLI commands, managing worktrees, tabs, and surfaces programmatically,"
    + " or when inside a CherryLily terminal session."

  // MARK: - Claude Code.

  static let claudeSkill = """
    ---
    name: \(skillName)
    description: \(description)
    ---

    # CherryLily CLI

    Control CherryLily from the terminal. The `cherrylily` command is available in all CherryLily terminal sessions.

    ## CRITICAL: ID Tracking

    **NEVER call `cherrylily tab new` or `cherrylily surface split` without capturing
    the output.** These commands print the new resource UUID to stdout. You MUST
    capture it into a variable — without it you cannot target the resource afterward.

    **NEVER omit `-t` and `-s` flags when targeting a resource you created.**
    The environment variables `$SUPACODE_TAB_ID` and `$SUPACODE_SURFACE_ID` refer
    to the shell session you are running in, NOT to any tab or surface you created.
    If you omit `-t`/`-s`, the command targets your own shell — not the new resource.

    For new tabs, the initial surface ID equals the tab ID.

    ### Correct pattern — ALWAYS follow this:

    **Run all related commands in a SINGLE Bash call** so captured variables
    are available to subsequent commands. If you split across tool calls,
    variables like `$TAB_ID` will be lost.

    ```sh
    # 1. ALWAYS capture the UUID from tab new / surface split.
    TAB_ID=$(cherrylily tab new -i "npm start")

    # 2. ALWAYS pass -t and -s explicitly when targeting created resources.
    #    For new tabs: surface ID = tab ID.
    SPLIT_ID=$(cherrylily surface split -t "$TAB_ID" -s "$TAB_ID" -d v -i "npm test")

    # 3. ALWAYS use captured IDs for subsequent operations.
    cherrylily surface focus -t "$TAB_ID" -s "$SPLIT_ID" -i "echo hello"
    cherrylily surface close -t "$TAB_ID" -s "$SPLIT_ID"
    cherrylily tab close -t "$TAB_ID"
    ```

    ### WRONG — never do this:

    ```sh
    # BAD: not capturing the UUID — you lose the reference.
    cherrylily tab new -i "npm start"

    # BAD: missing -t/-s — this targets your own shell, not the new tab.
    cherrylily surface split -d v -i "npm test"

    # BAD: splitting commands across separate Bash calls — variables are lost.
    # Call 1: TAB_ID=$(cherrylily tab new)
    # Call 2: cherrylily surface split -t "$TAB_ID" ...  ← $TAB_ID is empty!
    ```

    ## Environment

    Inside CherryLily terminals, these environment variables are set automatically:

    | Variable | Description |
    |----------|-------------|
    | `SUPACODE_WORKTREE_ID` | Current worktree (percent-encoded path). |
    | `SUPACODE_TAB_ID` | Current tab UUID (your shell's tab, not created ones). |
    | `SUPACODE_SURFACE_ID` | Current surface UUID (your shell's surface, not created ones). |
    | `SUPACODE_REPO_ID` | Current repository (percent-encoded path). |
    | `SUPACODE_SOCKET_PATH` | Socket for app communication. |

    `-w`, `-t`, `-s`, `-r` default to these when omitted. This is only useful for
    targeting **your own** session. For anything you create, pass explicit IDs.

    ## Commands

    ### App

    ```
    cherrylily                          # Bring CherryLily to front.
    cherrylily open                     # Same as above.
    ```

    ### Worktree

    ```
    cherrylily worktree list [-f]                   # List worktree IDs (-f = focused only).
    cherrylily worktree focus [-w <id>]            # Focus worktree.
    cherrylily worktree run [-w <id>]              # Run the worktree script.
    cherrylily worktree stop [-w <id>]             # Stop the running script.
    cherrylily worktree archive [-w <id>]          # Archive worktree.
    cherrylily worktree unarchive [-w <id>]        # Unarchive worktree.
    cherrylily worktree delete [-w <id>]           # Delete worktree.
    cherrylily worktree pin [-w <id>]              # Pin worktree.
    cherrylily worktree unpin [-w <id>]            # Unpin worktree.
    ```

    ### Tab

    ```
    cherrylily tab list [-w <id>] [-f]                              # List tab UUIDs in worktree (-f = focused only).
    cherrylily tab focus [-w <id>] [-t <id>]                      # Focus tab.
    cherrylily tab new [-w <id>] [-i <cmd>] [-n <uuid>]           # Create new tab (prints UUID to stdout).
    cherrylily tab close [-w <id>] [-t <id>]                      # Close tab.
    ```

    ### Surface

    ```
    cherrylily surface list [-w <id>] [-t <id>] [-f]                                              # List surface UUIDs in tab (-f = focused only).
    cherrylily surface focus [-w <id>] [-t <id>] [-s <id>] [-i <cmd>]                         # Focus surface.
    cherrylily surface split [-w <id>] [-t <id>] [-s <id>] [-i <cmd>] [-d h|v] [-n <uuid>]    # Split (prints UUID to stdout).
    cherrylily surface close [-w <id>] [-t <id>] [-s <id>]                                     # Close surface.
    ```

    ### Repository

    ```
    cherrylily repo list                                                     # List repository IDs.
    cherrylily repo open <path>                                              # Open repository.
    cherrylily repo worktree-new [-r <id>] [--branch <name>] [--base <ref>] [--fetch]  # Create worktree.
    ```

    ### Settings

    ```
    cherrylily settings [<section>]        # Open settings (general|notifications|worktrees|developer|shortcuts|updates|github).
    cherrylily settings repo [-r <id>]     # Open repository settings.
    ```

    ### Socket

    ```
    cherrylily socket                      # List active socket paths.
    ```

    ## Flag Reference

    | Flag | Short | Default | Description |
    |------|-------|---------|-------------|
    | `--worktree` | `-w` | `$SUPACODE_WORKTREE_ID` | Worktree ID. |
    | `--tab` | `-t` | `$SUPACODE_TAB_ID` | Tab UUID. |
    | `--surface` | `-s` | `$SUPACODE_SURFACE_ID` | Surface UUID. |
    | `--repo` | `-r` | `$SUPACODE_REPO_ID` | Repository ID. |
    | `--input` | `-i` | — | Command to run in the terminal. |
    | `--direction` | `-d` | `horizontal` | Split direction (`horizontal`/`h` or `vertical`/`v`). |
    | `--id` | `-n` | random | UUID for new tab/surface. |
    """

  // MARK: - Codex.

  // Codex uses SKILL.md (with frontmatter) + AGENTS.md.
  static let codexSkillMd = """
    ---
    name: \(skillName)
    description: \(description)
    version: 1.0.0
    ---

    # CherryLily CLI

    Control CherryLily from the terminal. The `cherrylily` command is available in all CherryLily terminal sessions.

    ## CRITICAL: ID Tracking

    **NEVER call `cherrylily tab new` or `cherrylily surface split` without capturing
    the output.** They print the new UUID to stdout. Without it you cannot target
    the resource afterward.

    **NEVER omit `-t`/`-s` when targeting a created resource.** The env vars point
    to your own shell, not to anything you created.

    For new tabs, surface ID = tab ID.

    ### Correct:

    ```sh
    TAB_ID=$(cherrylily tab new -i "npm start")
    SPLIT_ID=$(cherrylily surface split -t "$TAB_ID" -s "$TAB_ID" -d v -i "npm test")
    cherrylily surface close -t "$TAB_ID" -s "$SPLIT_ID"
    cherrylily tab close -t "$TAB_ID"
    ```

    ### WRONG:

    ```sh
    cherrylily tab new -i "npm start"           # BAD: not captured
    cherrylily surface split -d v -i "test"     # BAD: missing -t/-s, targets your shell
    ```

    ## Commands

    - `cherrylily worktree [list [-f]|focus|run|stop|archive|unarchive|delete|pin|unpin] [-w <id>]`
    - `cherrylily tab [list [-w] [-f]|focus|new|close] [-w <id>] [-t <id>] [-i <cmd>] [-n <uuid>]`
    - `cherrylily surface [list [-w] [-t] [-f]|focus|split|close] [-w <id>] [-t <id>] [-s <id>] [-i <cmd>] [-d h|v] [-n <uuid>]`
    - `cherrylily repo [list | open <path> | worktree-new [-r <id>] [--branch] [--base] [--fetch]]`
    - `cherrylily settings [<section>]`
    - `cherrylily socket`

    `list` outputs one ID per line (percent-encoded for worktrees/repos, UUIDs for tabs/surfaces).
    Use these IDs directly as `-w`, `-t`, `-s`, `-r` flag values.

    Flags: `-w` (worktree), `-t` (tab), `-s` (surface), `-r` (repo), `-i` (input), `-d` (direction), `-n` (new ID).
    Env var defaults only target your own shell session. Pass explicit IDs for created resources.
    """

  static let codexAgentsMd = """
    # CherryLily CLI

    \(description)

    ## CRITICAL: ID Tracking

    **NEVER call `cherrylily tab new` or `cherrylily surface split` without capturing
    the output.** They print the new UUID to stdout. Without it you cannot target
    the resource afterward.

    **NEVER omit `-t`/`-s` when targeting a created resource.** The env vars point
    to your own shell, not to anything you created.

    For new tabs, surface ID = tab ID.

    ### Correct:

    ```sh
    TAB_ID=$(cherrylily tab new -i "npm start")
    SPLIT_ID=$(cherrylily surface split -t "$TAB_ID" -s "$TAB_ID" -d v -i "npm test")
    cherrylily surface close -t "$TAB_ID" -s "$SPLIT_ID"
    cherrylily tab close -t "$TAB_ID"
    ```

    ### WRONG:

    ```sh
    cherrylily tab new -i "npm start"           # BAD: not captured
    cherrylily surface split -d v -i "test"     # BAD: missing -t/-s, targets your shell
    ```

    Flags: `-w` (worktree), `-t` (tab), `-s` (surface), `-r` (repo), `-i` (input), `-d` (direction), `-n` (new ID).
    Env var defaults only target your own shell session. Pass explicit IDs for created resources.
    """
}
