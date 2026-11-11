/// `completions` — print a shell completion script for panthalassa.
///
/// Source the generated script in your shell profile to get tab completion of
/// subcommands and flags:
///
/// ```bash
///   # Bash
///   source <(panthalassa completions --shell bash)
///
///   # Zsh
///   source <(panthalassa completions --shell zsh)
///
///   # Fish
///   panthalassa completions --shell fish | source
/// ```
///
/// The script is regenerated whenever the command surface changes; re-source it
/// after upgrading panthalassa.
library;

import 'package:args/command_runner.dart';

import 'console.dart';

/// Shells for which completion scripts can be generated.
enum CompletionShell { bash, zsh, fish }

/// Prints a shell completion script covering subcommands, global flags, and the
/// most-used per-command flags.
final class CompletionsCommand extends Command<void> {
  CompletionsCommand() {
    argParser.addOption(
      'shell',
      abbr: 's',
      allowed: ['bash', 'zsh', 'fish'],
      defaultsTo: 'bash',
      valueHelp: 'shell',
      help: 'Target shell: bash, zsh, or fish (default: bash).',
    );
  }

  @override
  String get name => 'completions';

  @override
  String get description =>
      'Print a shell completion script for panthalassa.';

  @override
  String get invocation => 'panthalassa completions [--shell bash|zsh|fish]';

  @override
  String get usageFooter => usageExamples([
    'panthalassa completions --shell bash > ~/.bash_completion.d/panthalassa',
    'panthalassa completions --shell zsh > ~/.zsh/completion/_panthalassa',
  ]);

  @override
  Future<void> run() async {
    final shell = CompletionShell.values.firstWhere(
      (s) => s.name == (argResults!['shell'] as String),
      orElse: () => CompletionShell.bash,
    );
    final script = _scriptFor(shell);
    console.writeRaw(script);
    if (!script.endsWith('\n')) console.writeRaw('\n');
  }

  String _scriptFor(CompletionShell shell) {
    switch (shell) {
      case CompletionShell.bash:
        return _bash;
      case CompletionShell.zsh:
        return _zsh;
      case CompletionShell.fish:
        return _fish;
    }
  }

  static const _bash = r'''# panthalassa shell completion (bash)
# Source with:  source <(panthalassa completions --shell bash)

_panthalassa_commands() {
  local commands="detect formats parse render view batch digest version completions"
  COMPREPLY=( $(compgen -W "$commands" -- "${COMP_WORDS[COMP_CWORD]}") )
}

_panthalassa_global_flags() {
  local flags="--version --color --no-color --help"
  COMPREPLY=( $(compgen -W "$flags" -- "${COMP_WORDS[COMP_CWORD]}") )
}

_panthalassa_opts() {
  local cmd="${COMP_WORDS[1]}"
  case "$cmd" in
    detect)
      local opts="--json --require-match --filename --mime --help"
      COMPREPLY=( $(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}") )
      ;;
    formats)
      local opts="--json --brief --verbose --help"
      COMPREPLY=( $(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}") )
      ;;
    parse)
      local opts="--json --text --metadata --out --preview-lines --attachment-text --sync --quiet --filename --mime --strict --max-text-chars --max-metadata --max-json-nodes --max-table-rows --max-table-columns --max-attachments --max-attachment-bytes --max-decompressed-bytes --max-decompressed-entry-bytes --max-recursion-depth --max-pages --max-segments --no-visual --no-structured-text --no-outline --no-tables --no-attachments --attachment-bytes --parse-attachments --annotations --form-fields --signatures --security-labels --reject-encrypted --help"
      COMPREPLY=( $(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}") )
      ;;
    render)
      local opts="--format --out --metadata --heading-base-level --sync --quiet --filename --mime --strict --max-text-chars --max-metadata --max-json-nodes --max-table-rows --max-table-columns --max-attachments --max-attachment-bytes --max-decompressed-bytes --max-decompressed-entry-bytes --max-recursion-depth --max-pages --max-segments --no-visual --no-structured-text --no-outline --no-tables --no-attachments --attachment-bytes --parse-attachments --help"
      COMPREPLY=( $(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}") )
      ;;
    view)
      local opts="--out --no-open --print-path --raw --json --sync --quiet --title --limit --all-rows --frame --all-frames --window-center --window-width --invert --filename --mime --strict --max-text-chars --max-metadata --max-json-nodes --max-table-rows --max-table-columns --max-attachments --max-attachment-bytes --max-decompressed-bytes --max-decompressed-entry-bytes --max-recursion-depth --max-pages --max-segments --no-visual --no-structured-text --no-outline --no-tables --no-attachments --attachment-bytes --parse-attachments --help"
      COMPREPLY=( $(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}") )
      ;;
    batch)
      local opts="--recursive --include --concurrency --out-dir --fail-fast --json --quiet --strict --max-text-chars --max-metadata --max-json-nodes --max-table-rows --max-table-columns --max-attachments --max-attachment-bytes --max-decompressed-bytes --max-decompressed-entry-bytes --max-recursion-depth --max-pages --max-segments --no-visual --no-structured-text --no-outline --no-tables --no-attachments --attachment-bytes --parse-attachments --help"
      COMPREPLY=( $(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}") )
      ;;
    digest)
      local opts="--algo --short --expect --json --quiet --strict --max-text-chars --max-metadata --max-json-nodes --max-table-rows --max-table-columns --max-attachments --max-attachment-bytes --max-decompressed-bytes --max-decompressed-entry-bytes --max-recursion-depth --max-pages --max-segments --help"
      COMPREPLY=( $(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}") )
      ;;
    version|completions)
      local opts="--shell --help"
      COMPREPLY=( $(compgen -W "$opts" -- "${COMP_WORDS[COMP_CWORD]}") )
      ;;
    *)
      COMPREPLY=()
      ;;
  esac
}

_panthalassa() {
  local cur prev words cword
  _get_comp_words_by_ref -n ":" cur prev words cword 2>/dev/null || {
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    words=("${COMP_WORDS[@]}")
    cword=$COMP_CWORD
  }

  # Complete the subcommand when no command has been chosen yet.
  if [ $cword -eq 1 ]; then
    _panthalassa_commands
    return
  fi

  local cmd="${words[1]}"
  case "$cmd" in
    --version|--color|--no-color|--help)
      _panthalassa_global_flags
      ;;
    detect|formats|parse|render|view|batch|digest|version|completions)
      _panthalassa_opts
      ;;
    *)
      COMPREPLY=()
      ;;
  esac
}

complete -F _panthalassa panthalassa
''';

  static const _zsh = r'''# panthalassa shell completion (zsh)
# Source with:  source <(panthalassa completions --shell zsh)

#compdef panthalassa

_panthalassa() {
  local -a commands
  commands=(detect formats parse render view batch digest version completions)

  if (( CURRENT == 2 )); then
    _describe 'panthalassa command' commands
    return
  fi

  local cmd="${words[2]}"
  case "$cmd" in
    detect)
      _arguments \
        '(--json)--json' \
        '(--require-match)--require-match' \
        '(--filename)--filename:' \
        '(--mime)--mime:' \
        '--help' \
        ;;
    formats)
      _arguments \
        '(--json)--json' \
        '(--brief)--brief' \
        '(--verbose)--verbose' \
        '--help' \
        ;;
    parse)
      _arguments \
        '(--json)--json' \
        '(--text)--text' \
        '(--metadata)--metadata' \
        '(--out)--out:' \
        '(--preview-lines)--preview-lines:' \
        '(--attachment-text)--attachment-text' \
        '(--sync)--sync' \
        '(--quiet)--quiet' \
        '(--filename)--filename:' \
        '(--mime)--mime:' \
        '(--strict)--strict' \
        '--help' \
        ;;
    render)
      _arguments \
        '(--format)--format:' \
        '(--out)--out:' \
        '(--metadata)--metadata' \
        '(--heading-base-level)--heading-base-level:' \
        '(--sync)--sync' \
        '(--quiet)--quiet' \
        '(--filename)--filename:' \
        '(--mime)--mime:' \
        '(--strict)--strict' \
        '--help' \
        ;;
    view)
      _arguments \
        '(--out)--out:' \
        '(--no-open)--no-open' \
        '(--print-path)--print-path' \
        '(--raw)--raw' \
        '(--json)--json' \
        '(--sync)--sync' \
        '(--quiet)--quiet' \
        '(--title)--title:' \
        '(--limit)--limit:' \
        '(--all-rows)--all-rows' \
        '(--frame)--frame:' \
        '(--all-frames)--all-frames' \
        '(--window-center)--window-center:' \
        '(--window-width)--window-width:' \
        '(--invert)--invert' \
        '(--filename)--filename:' \
        '(--mime)--mime:' \
        '(--strict)--strict' \
        '--help' \
        ;;
    batch)
      _arguments \
        '(--recursive)--recursive' \
        '(--include)--include:' \
        '(--concurrency)--concurrency:' \
        '(--out-dir)--out-dir:' \
        '(--fail-fast)--fail-fast' \
        '(--json)--json' \
        '(--quiet)--quiet' \
        '(--strict)--strict' \
        '--help' \
        ;;
    digest)
      _arguments \
        '(--algo)--algo:' \
        '(--short)--short' \
        '(--expect)--expect:' \
        '(--json)--json' \
        '(--quiet)--quiet' \
        '(--strict)--strict' \
        '--help' \
        ;;
    version)
      _arguments '--help' \
        ;;
    completions)
      _arguments \
        '(--shell)--shell:' \
        '--help' \
        ;;
  esac
}

_panthalassa "$@"
''';

  static const _fish = r'''# panthalassa shell completion (fish)
# Source with:  panthalassa completions --shell fish | source

function __panthalassa_commands
  echo detect formats parse render view batch digest version completions
end

function __panthalassa_complete --description 'Complete panthalassa subcommands and flags'
  set -l cmd (commandline -opc)

  # Complete the subcommand.
  if test (count $cmd) -eq 1
    __panthalassa_commands | string match -q "$argv[1]*" 2>/dev/null || true
    __panthalassa_commands | string match -- "$argv[1]*" 2>/dev/null || true
    return
  end

  set -l subcommand $cmd[2]
  switch $subcommand
    case detect
      echo --json --require-match --filename --mime --help
    case formats
      echo --json --brief --verbose --help
    case parse
      echo --json --text --metadata --out --preview-lines --attachment-text --sync --quiet --filename --mime --strict --help
    case render
      echo --format --out --metadata --heading-base-level --sync --quiet --filename --mime --strict --help
    case view
      echo --out --no-open --print-path --raw --json --sync --quiet --title --limit --all-rows --frame --all-frames --window-center --window-width --invert --filename --mime --strict --help
    case batch
      echo --recursive --include --concurrency --out-dir --fail-fast --json --quiet --strict --help
    case digest
      echo --algo --short --expect --json --quiet --strict --help
    case version
      echo --help
    case completions
      echo --shell --help
  end
end

complete -c panthalassa -f -a '(__panthalassa_complete)'
''';
}
