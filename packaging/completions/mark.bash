# bash completion for mark(1). Source it, or install it as
# $(brew --prefix)/etc/bash_completion.d/mark.
#
# Hand-written; see packaging/completions/_mark for why, and
# `the_man_page_and_completions_name_every_subcommand` in cli/src/main.rs for
# what stops it drifting from the CLI.

_mark_complete() {
    local current previous command
    current="${COMP_WORDS[COMP_CWORD]}"
    previous="${COMP_WORDS[COMP_CWORD-1]}"
    command="${COMP_WORDS[1]}"

    local commands="render toc tasks check ls grep stats doctor open tab theme goto reload sidebar nav"

    if [[ ${COMP_CWORD} -eq 1 ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${commands} --help --version" -- "${current}")
        return
    fi

    # An option that takes a value: complete the value, not another flag.
    case "${previous}" in
        --theme|--show)
            # Answered locally by the core, so this works with no app running.
            local themes
            themes=$(mark theme --list 2>/dev/null | awk 'NR>1 {print $1}')
            mapfile -t COMPREPLY < <(compgen -W "${themes}" -- "${current}")
            return
            ;;
        --prefix|--depth|--item)
            return
            ;;
        --import)
            mapfile -t COMPREPLY < <(compgen -f -- "${current}")
            return
            ;;
    esac

    local options=""
    case "${command}" in
        render) options="--html --ansi --plain --prefix --theme" ;;
        toc|stats) options="--json" ;;
        tasks) options="--open --json --depth" ;;
        check) options="--item --on --off --toggle --json" ;;
        ls) options="--json --depth --all" ;;
        grep) options="--json --ignore-case --depth" ;;
        doctor|reload|sidebar) options="--json" ;;
        open) options="--tab --json" ;;
        goto) options="--json" ;;
        nav) options="--up --parent --back --forward --json" ;;
        theme) options="--system --list --show --import --json" ;;
        tab)
            if [[ ${COMP_CWORD} -eq 2 ]]; then
                mapfile -t COMPREPLY < <(compgen -W "list select close" -- "${current}")
                return
            fi
            # --all belongs to `close` alone; offering it after `list` or
            # `select` would advertise a flag the binary rejects.
            if [[ "${COMP_WORDS[2]}" == "close" ]]; then
                options="--all --json"
            else
                options="--json"
            fi
            ;;
    esac

    if [[ "${current}" == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${options} --help" -- "${current}")
        return
    fi

    # Positionals. `grep` takes a pattern first and there is nothing useful to
    # offer for it, and `goto` takes an anchor, which needs the document parsed.
    case "${command}" in
        ls|nav) mapfile -t COMPREPLY < <(compgen -d -- "${current}") ;;
        grep|goto|theme) ;;
        tab)
            # Live tab indices, but only if the app is already listening:
            # completion must never launch a GUI.
            local tabs
            tabs=$(MARK_NO_LAUNCH=1 mark tab list 2>/dev/null | awk '{print $2}')
            mapfile -t COMPREPLY < <(compgen -W "${tabs}" -- "${current}")
            ;;
        *) mapfile -t COMPREPLY < <(compgen -f -- "${current}") ;;
    esac
}

complete -F _mark_complete mark mark-cli
