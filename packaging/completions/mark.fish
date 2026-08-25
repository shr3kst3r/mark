# fish completion for mark(1). Install as
# ~/.config/fish/completions/mark.fish, or let the formula do it.
#
# Hand-written; see packaging/completions/_mark for why, and
# `the_man_page_and_completions_name_every_subcommand` in cli/src/main.rs for
# what stops it drifting from the CLI.

function __mark_no_subcommand
    for token in (commandline -opc)[2..-1]
        switch $token
            case render toc tasks check ls grep stats doctor open tab theme goto reload sidebar nav
                return 1
        end
    end
    return 0
end

# Answered locally by the core, so this works with no app running.
function __mark_themes
    mark theme --list 2>/dev/null | string replace -r '^(\S+)\s+.*' '$1' | tail -n +2
end

# Live tabs, but never a launch: completion that starts a GUI is a bug.
function __mark_tabs
    MARK_NO_LAUNCH=1 mark tab list 2>/dev/null | string replace -r '^.\s+(\d+)\s+.*' '$1'
end

complete -c mark -f
complete -c mark -n __mark_no_subcommand -a render -d 'Render a document to stdout'
complete -c mark -n __mark_no_subcommand -a toc -d 'Print the heading tree'
complete -c mark -n __mark_no_subcommand -a tasks -d 'List every task in a file or directory'
complete -c mark -n __mark_no_subcommand -a check -d 'Set, clear, or flip one checkbox in place'
complete -c mark -n __mark_no_subcommand -a ls -d 'List markdown files with titles and task counts'
complete -c mark -n __mark_no_subcommand -a grep -d 'Search, reporting the heading each match sits under'
complete -c mark -n __mark_no_subcommand -a stats -d 'Per-stage timings and counters'
complete -c mark -n __mark_no_subcommand -a doctor -d 'Environment report for a bug report'
complete -c mark -n __mark_no_subcommand -a open -d 'Open a file in a tab, or root the sidebar at a directory'
complete -c mark -n __mark_no_subcommand -a tab -d "List, select, and close the app's tabs"
complete -c mark -n __mark_no_subcommand -a theme -d 'Choose a theme, or inspect the ones there are'
complete -c mark -n __mark_no_subcommand -a goto -d 'Scroll the front document to a heading anchor'
complete -c mark -n __mark_no_subcommand -a reload -d 'Re-read the front document from disk'
complete -c mark -n __mark_no_subcommand -a sidebar -d 'Report the sidebar root, breadcrumb, and history'
complete -c mark -n __mark_no_subcommand -a nav -d "Move the sidebar's root"

# --- files and directories --------------------------------------------------
complete -c mark -n '__fish_seen_subcommand_from render toc tasks check stats open grep' -F
complete -c mark -n '__fish_seen_subcommand_from ls nav' -a '(__fish_complete_directories)'

# --- per-subcommand flags ---------------------------------------------------
complete -c mark -n '__fish_seen_subcommand_from render' -l html -d 'A complete, self-contained HTML document'
complete -c mark -n '__fish_seen_subcommand_from render' -l ansi -d 'Styled terminal output'
complete -c mark -n '__fish_seen_subcommand_from render' -l plain -d 'No escape sequences'
complete -c mark -n '__fish_seen_subcommand_from render' -l prefix -r -d 'Only the first N top-level blocks'
complete -c mark -n '__fish_seen_subcommand_from render' -l theme -r -a '(__mark_themes)' -d 'Theme to render with'

complete -c mark -n '__fish_seen_subcommand_from toc tasks check ls grep stats doctor open theme goto reload sidebar nav tab' -l json -d 'Machine-readable output'

complete -c mark -n '__fish_seen_subcommand_from tasks' -l open -d 'Only unchecked tasks'
complete -c mark -n '__fish_seen_subcommand_from tasks ls grep' -l depth -r -d 'Levels to descend'
complete -c mark -n '__fish_seen_subcommand_from ls' -l all -d 'Include non-markdown files'
complete -c mark -n '__fish_seen_subcommand_from grep' -s i -l ignore-case -d 'Case-insensitive matching'

complete -c mark -n '__fish_seen_subcommand_from check' -l item -r -d 'Task index in document order'
complete -c mark -n '__fish_seen_subcommand_from check' -l on -d 'Check the box'
complete -c mark -n '__fish_seen_subcommand_from check' -l off -d 'Uncheck the box'
complete -c mark -n '__fish_seen_subcommand_from check' -l toggle -d 'Flip it (the default)'

complete -c mark -n '__fish_seen_subcommand_from open' -l tab -d 'Add the tab without moving the reader'

complete -c mark -n '__fish_seen_subcommand_from nav' -l up -d "The current root's parent"
complete -c mark -n '__fish_seen_subcommand_from nav' -l parent -d "The current root's parent"
complete -c mark -n '__fish_seen_subcommand_from nav' -l back -d 'The previous root'
complete -c mark -n '__fish_seen_subcommand_from nav' -l forward -d 'Forward again, after --back'

complete -c mark -n '__fish_seen_subcommand_from theme' -l list -d 'List the available themes'
complete -c mark -n '__fish_seen_subcommand_from theme' -l show -r -a '(__mark_themes)' -d "Dump a theme's palette and CSS"
complete -c mark -n '__fish_seen_subcommand_from theme' -l import -r -F -d 'Convert a .tmTheme or base16 scheme'
complete -c mark -n '__fish_seen_subcommand_from theme' -a '(__mark_themes)' -d 'Theme'

# --- tab's own actions ------------------------------------------------------
complete -c mark -n '__fish_seen_subcommand_from tab; and not __fish_seen_subcommand_from list select close' -a list -d 'Every open tab, in bar order'
complete -c mark -n '__fish_seen_subcommand_from tab; and not __fish_seen_subcommand_from list select close' -a select -d 'Bring a tab to the front'
complete -c mark -n '__fish_seen_subcommand_from tab; and not __fish_seen_subcommand_from list select close' -a close -d 'Close a tab'
complete -c mark -n '__fish_seen_subcommand_from select close' -a '(__mark_tabs)' -d 'Tab'
