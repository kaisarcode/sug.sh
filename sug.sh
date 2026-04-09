#!/bin/bash
# sug.sh - Shell token autosuggestion integration layer
# Summary: Adds readline-aware token prediction to interactive bash.
# Author:  KaisarCode
# Website: https://kaisarcode.com
# License: https://www.gnu.org/licenses/gpl-3.0.html

# File contract:
# - Source this file from an interactive Bash session.
# - The matcher stays integrated in this script.
# - The widget remains a terminal line rendered below the prompt.

# Prints usage help.
# @return 0 Always.
sug_help() {
    cat <<'EOF'
Usage:
    source sug.sh -m /path/to/map.txt [options]

Options:
    -m, --map PATH         Candidate map. Repeatable.
    -n, --limit N          Maximum candidate count
    -t, --threshold FLOAT  Minimum similarity threshold (0..1)
    -h, --help             Show help

Bindings:
    Ctrl+Up     Previous candidate
    Ctrl+Down   Next candidate
    Tab         Accept active candidate
    Esc         Cancel suggestion

Examples:
    . ./sug.sh -m ./map.txt
EOF
}

# Checks if the script is being sourced rather than executed.
# @return 0 if sourced, 1 if executed.
sug_is_sourced() {
    [[ ${BASH_SOURCE[0]} != "$0" ]]
}

# Prints an error message to standard error.
# @param $1 Error message.
# @return 1 Always.
sug_fail() {
    printf 'Error: %s\n' "$1" >&2
    return 1
}

# Initializes configuration variables with default values.
# @return 0 Always.
sug_set_defaults() {
    SUG_MAPS=${SUG_MAPS:-}
    SUG_MAP_PATHS=()
    if [[ -n $SUG_MAPS ]]; then
        read -r -a SUG_MAP_PATHS <<< "$SUG_MAPS"
    fi
    [[ -n ${SUG_LIMIT:-} ]] || SUG_LIMIT='8'
    [[ -n ${SUG_THRESHOLD:-} ]] || SUG_THRESHOLD='0.3'
    [[ -n ${SUG_MIN:-} ]] || SUG_MIN='3'
    return 0
}

# Validates that a value is a non-negative integer.
# @param $1 Option name for error reporting.
# @param $2 Value to validate.
# @return 0 if valid, 1 otherwise.
sug_validate_number() {
    case "$2" in
        ''|*[!0-9]*)
            sug_fail "$1 requires a non-negative integer."
            return 1
            ;;
    esac

    return 0
}

# Parses command-line arguments and updates configuration.
# @return 0 on success, 1 on error, 2 if help was requested.
sug_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--map)
                [[ $# -ge 2 ]] || {
                    sug_fail 'Missing value for -m|--map.'
                    return 1
                }
                SUG_MAP_PATHS+=("$2")
                SUG_MAPS="${SUG_MAPS}${SUG_MAPS:+ }$2"
                shift 2
                ;;
            -n|--limit)
                [[ $# -ge 2 ]] || {
                    sug_fail 'Missing value for -n|--limit.'
                    return 1
                }
                sug_validate_number '-n|--limit' "$2" || return 1
                SUG_LIMIT="$2"
                shift 2
                ;;
            -t|--threshold)
                [[ $# -ge 2 ]] || {
                    sug_fail 'Missing value for -t|--threshold.'
                    return 1
                }
                SUG_THRESHOLD="$2"
                shift 2
                ;;
            -h|--help)
                sug_help
                return 2
                ;;
            *)
                sug_fail "Unknown option: $1"
                return 1
                ;;
        esac
    done

    return 0
}

# Validates that the configuration is complete and the map file exists.
# @return 0 if valid, 1 otherwise.
sug_validate_config() {
    (( ${#SUG_MAP_PATHS[@]} > 0 )) || {
        sug_fail 'Missing required map. Use -m|--map PATH.'
        return 1
    }

    local sug_vc_map
    for sug_vc_map in "${SUG_MAP_PATHS[@]}"; do
        [[ -f $sug_vc_map ]] || {
            sug_fail "Map not found: $sug_vc_map"
            return 1
        }
    done

    return 0
}

# Resets the internal state of the suggestion engine.
# @return 0 Always.
sug_reset_state() {
    SUG_TOKEN_START=0
    SUG_TOKEN_END=0
    SUG_TOKEN_TEXT=''
    SUG_LAST_WIDGET_TEXT=''
    SUG_ACTIVE_INDEX=0
    SUG_WIDGET_VISIBLE=0
    SUG_CANCELLED_LINE=''
    SUG_CANCELLED_POINT=''
    SUG_CANDIDATE_COUNT=0
    SUG_TAB_MODE=''
    SUG_CANDIDATES=()
    return 0
}

# Returns the active candidate if it exists.
# @return 0 Always.
sug_get_active_candidate() {
    if (( SUG_CANDIDATE_COUNT > 0 )) && (( SUG_ACTIVE_INDEX < SUG_CANDIDATE_COUNT )); then
        printf '%s' "${SUG_CANDIDATES[SUG_ACTIVE_INDEX]}"
    fi

    return 0
}

# Checks if a character is a token separator.
# @param $1 Character to check.
# @return 0 if it is a separator, 1 otherwise.
sug_is_separator() {
    case "$1" in
        ''|[[:space:]]|[\;\|\&\<\>\(\)\{\}\[\]=:,\"\'\\])
            return 0
            ;;
    esac

    return 1
}

# Checks if the script is running in a valid TTY.
# @return 0 if it has a TTY, 1 otherwise.
sug_has_tty() {
    [[ -t 1 && -n ${TERM:-} && $TERM != 'dumb' ]]
}

# Removes the prompt hook from PROMPT_COMMAND.
# @return 0 Always.
sug_remove_prompt_hook() {
    local hook='sug_prompt_hook'

    case ";${PROMPT_COMMAND:-};" in
        *";${hook};"*)
            PROMPT_COMMAND=${PROMPT_COMMAND//;${hook};/;}
            PROMPT_COMMAND=${PROMPT_COMMAND/#${hook};/}
            PROMPT_COMMAND=${PROMPT_COMMAND/%;${hook}/}
            [[ $PROMPT_COMMAND != "$hook" ]] || PROMPT_COMMAND=''
            PROMPT_COMMAND=${PROMPT_COMMAND#;}
            PROMPT_COMMAND=${PROMPT_COMMAND%;}
            ;;
    esac

    return 0
}

# Installs an EXIT trap so temporary files are removed on shell exit.
# @return 0 Always.
sug_install_exit_hook() {
    local sug_ieh_trap_def=''

    [[ ${SUG_EXIT_HOOK_INSTALLED:-0} == '1' ]] && return 0

    sug_ieh_trap_def=$(trap -p EXIT)
    SUG_ORIGINAL_EXIT_TRAP_DEF="$sug_ieh_trap_def"

    trap 'sug_cleanup_on_exit' EXIT
    SUG_EXIT_HOOK_INSTALLED=1
    return 0
}

# Restores the previous EXIT trap.
# @return 0 Always.
sug_restore_exit_hook() {
    if [[ ${SUG_EXIT_HOOK_INSTALLED:-0} != '1' ]]; then
        return 0
    fi

    if [[ -n ${SUG_ORIGINAL_EXIT_TRAP_DEF:-} ]]; then
        eval -- "$SUG_ORIGINAL_EXIT_TRAP_DEF"
    else
        trap - EXIT
    fi

    SUG_ORIGINAL_EXIT_TRAP_DEF=''
    SUG_EXIT_HOOK_INSTALLED=0
    return 0
}

# Saves current readline bindings so they can be restored on disable.
# @return 0 on success, 1 on failure.
sug_capture_bindings() {
    [[ -n ${SUG_BINDINGS_FILE:-} && -f ${SUG_BINDINGS_FILE:-} ]] && return 0

    SUG_BINDINGS_FILE="$(mktemp)" || return 1
    bind -p > "$SUG_BINDINGS_FILE" || return 1
    return 0
}

# Removes temporary files created by sug.sh.
# @return 0 Always.
sug_cleanup_temp_files() {
    [[ -n ${SUG_TOKEN_FILE:-} ]] && rm -f "$SUG_TOKEN_FILE"
    [[ -n ${SUG_BINDINGS_FILE:-} && -f ${SUG_BINDINGS_FILE:-} ]] && rm -f "$SUG_BINDINGS_FILE"
    SUG_TOKEN_FILE=''
    SUG_BINDINGS_FILE=''
    return 0
}

# Cleans sug.sh runtime leftovers when the shell exits.
# @return 0 Always.
sug_cleanup_on_exit() {
    sug_cleanup_temp_files
    return 0
}

# Restores readline bindings captured before enable.
# @return 0 Always.
sug_restore_bindings() {
    if [[ -n ${SUG_BINDINGS_FILE:-} && -f ${SUG_BINDINGS_FILE:-} ]]; then
        bind -f "$SUG_BINDINGS_FILE"
        rm -f "$SUG_BINDINGS_FILE"
    fi

    SUG_BINDINGS_FILE=''
    return 0
}

# Toggles the Tab key binding between suggestion accept and native completion.
# @param $1 Target mode ('suggest' or 'native').
# @return 0 Always.
sug_toggle_tab() {
    local sug_tt_target="$1"

    [[ $SUG_TAB_MODE == "$sug_tt_target" ]] && return 0

    if [[ $sug_tt_target == 'suggest' ]]; then
        bind -x '"\C-i":"sug_accept"'
    else
        bind "\"\\C-i\": ${SUG_ORIGINAL_TAB_CMD:-complete}"
    fi

    SUG_TAB_MODE="$sug_tt_target"
    return 0
}

# Detects the token at the current cursor position in the buffer.
# @param $1 Buffer string.
# @param $2 Cursor point.
# @return 0 Always.
sug_detect_token() {
    local sug_dt_buffer="$1"
    local sug_dt_point="$2"
    local sug_dt_length=${#sug_dt_buffer}
    local sug_dt_index
    local sug_dt_char

    (( sug_dt_point > sug_dt_length )) && sug_dt_point=$sug_dt_length

    SUG_TOKEN_START=$sug_dt_point
    for (( sug_dt_index=sug_dt_point - 1; sug_dt_index >= 0; sug_dt_index-- )); do
        sug_dt_char=${sug_dt_buffer:sug_dt_index:1}
        sug_is_separator "$sug_dt_char" && break
        SUG_TOKEN_START=$sug_dt_index
    done

    SUG_TOKEN_END=$sug_dt_point
    for (( sug_dt_index=sug_dt_point; sug_dt_index < sug_dt_length; sug_dt_index++ )); do
        sug_dt_char=${sug_dt_buffer:sug_dt_index:1}
        sug_is_separator "$sug_dt_char" && break
        SUG_TOKEN_END=$((sug_dt_index + 1))
    done

    if (( SUG_TOKEN_START < SUG_TOKEN_END )); then
        SUG_TOKEN_TEXT=${sug_dt_buffer:SUG_TOKEN_START:SUG_TOKEN_END-SUG_TOKEN_START}
    else
        SUG_TOKEN_TEXT=''
    fi

    return 0
}

# Loads the candidate map from the specified file.
# @return 0 Always.
sug_load_map() {
    [[ -n ${SUG_TOKEN_FILE:-} ]] && rm -f "$SUG_TOKEN_FILE"
    SUG_TOKEN_FILE="$(mktemp)" || return 1

    sort "${SUG_MAP_PATHS[@]}" | uniq -c | sort -rn | sed 's/^[[:space:]]*//' > "$SUG_TOKEN_FILE"
    return 0
}

# Finds candidates that match the given token.
# @param $1 Token to match.
# @return 0 Always.
sug_match_token() {
    local sug_mt_token="$1"

    SUG_CANDIDATES=()
    SUG_CANDIDATE_COUNT=0
    SUG_ACTIVE_INDEX=0
    [[ -n $sug_mt_token ]] || return 0

    mapfile -t SUG_CANDIDATES < <(
        awk -v query="$sug_mt_token" -v limit="$SUG_LIMIT" -v threshold="$SUG_THRESHOLD" '
            function get_prefix_score(q, c) {
                ql = length(q); cl = length(c);
                min = (ql < cl ? ql : cl);
                pl = 0;
                for (i = 1; i <= min; i++) {
                    if (substr(q, i, 1) != substr(c, i, 1)) break;
                    pl++;
                }
                return pl / ql;
            }
            function get_gram_score(q, c) {
                ql = length(q); cl = length(c);
                if (ql < 2 || cl < 2) return (index(c, q) ? 1.0 : 0.0);
                split("", qg); split("", cg);
                for (i = 1; i < ql; i++) qg[substr(q, i, 2)]++;
                for (i = 1; i < cl; i++) cg[substr(c, i, 2)]++;
                common = 0;
                for (g in qg) {
                    if (g in cg) common += (qg[g] < cg[g] ? qg[g] : cg[g]);
                }
                return (2.0 * common) / (ql + cl - 2);
            }
            {
                count = $1;
                token = $0;
                sub(/^[0-9]+ /, "", token);
                if (token == query) next;
                p_score = get_prefix_score(query, token);
                g_score = get_gram_score(query, token);
                similarity = (p_score * 0.7) + (g_score * 0.3);
                if (similarity < threshold && index(token, query) == 0) next;
                rank = similarity * (1.0 + (count / 1000.0));
                if (rank > 0) print rank "\t" token;
            }
        ' "$SUG_TOKEN_FILE" | sort -rn | head -n "$SUG_LIMIT" | cut -f2-
    )

    SUG_CANDIDATE_COUNT=${#SUG_CANDIDATES[@]}
    return 0
}

# Clears the suggestion widget from the terminal.
# @return 0 Always.
sug_clear_widget() {
    if sug_has_tty; then
        printf '\033[s\033[1B\r\033[2K\033[u'
    fi

    SUG_WIDGET_VISIBLE=0
    SUG_LAST_WIDGET_TEXT=''
    return 0
}

# Draws the suggestion widget with the specified text.
# @param $1 Text to display.
# @return 0 Always.
sug_draw_widget() {
    local sug_dw_text="$1"

    sug_has_tty || return 0

    if [[ -z $sug_dw_text ]]; then
        sug_clear_widget
        return 0
    fi

    if (( SUG_WIDGET_VISIBLE == 1 )) && [[ $sug_dw_text == "${SUG_LAST_WIDGET_TEXT:-}" ]]; then
        return 0
    fi

    printf '\033[s\033[1B\r\033[2K'
    printf '\033[2m  %s\033[0m' "$sug_dw_text"
    printf '\033[u'

    SUG_WIDGET_VISIBLE=1
    SUG_LAST_WIDGET_TEXT="$sug_dw_text"
    return 0
}

# Cancels the current suggestion and clears the widget.
# @return 0 Always.
sug_cancel() {
    SUG_CANCELLED_LINE="$READLINE_LINE"
    SUG_CANCELLED_POINT="$READLINE_POINT"
    SUG_CANDIDATES=()
    SUG_CANDIDATE_COUNT=0
    SUG_ACTIVE_INDEX=0
    sug_toggle_tab "native"
    sug_clear_widget
    return 0
}

# Checks if the current state matches the last cancelled state.
# @return 0 if cancelled state matches, 1 otherwise.
sug_is_cancelled_state() {
    [[ $READLINE_LINE == "$SUG_CANCELLED_LINE" && $READLINE_POINT == "$SUG_CANCELLED_POINT" ]]
}

# Refreshes the suggestion based on the current readline state.
# @return 0 Always.
sug_refresh() {
    local sug_re_candidate=''

    [[ ${SUG_ENABLED:-0} == '1' ]] || return 0

    if sug_is_cancelled_state; then
        SUG_CANDIDATES=()
        SUG_CANDIDATE_COUNT=0
        SUG_ACTIVE_INDEX=0
        sug_toggle_tab "native"
        sug_clear_widget
        return 0
    fi

    SUG_CANCELLED_LINE=''
    SUG_CANCELLED_POINT=''

    sug_detect_token "$READLINE_LINE" "$READLINE_POINT"

    if [[ -z $SUG_TOKEN_TEXT || ${#SUG_TOKEN_TEXT} -lt $SUG_MIN ]]; then
        SUG_CANDIDATES=()
        SUG_CANDIDATE_COUNT=0
        SUG_ACTIVE_INDEX=0
        sug_toggle_tab "native"
        sug_clear_widget
        return 0
    fi

    sug_match_token "$SUG_TOKEN_TEXT"

    if (( SUG_CANDIDATE_COUNT == 0 )); then
        sug_toggle_tab "native"
        sug_clear_widget
        return 0
    fi

    (( SUG_ACTIVE_INDEX < SUG_CANDIDATE_COUNT )) || SUG_ACTIVE_INDEX=0
    sug_re_candidate=$(sug_get_active_candidate)

    if [[ -z $sug_re_candidate ]]; then
        sug_toggle_tab "native"
        sug_clear_widget
        return 0
    fi

    sug_toggle_tab "suggest"
    sug_draw_widget "$sug_re_candidate"
    return 0
}

# Moves to the next candidate in the list.
# @return 0 Always.
sug_next() {
    if (( SUG_CANDIDATE_COUNT > 0 )); then
        if (( SUG_ACTIVE_INDEX < SUG_CANDIDATE_COUNT - 1 )); then
            ((SUG_ACTIVE_INDEX++))
        else
            SUG_ACTIVE_INDEX=0
        fi

        sug_draw_widget "$(sug_get_active_candidate)"
    else
        sug_refresh
    fi

    return 0
}

# Moves to the previous candidate in the list.
# @return 0 Always.
sug_prev() {
    if (( SUG_CANDIDATE_COUNT > 0 )); then
        if (( SUG_ACTIVE_INDEX > 0 )); then
            ((SUG_ACTIVE_INDEX--))
        else
            SUG_ACTIVE_INDEX=$((SUG_CANDIDATE_COUNT - 1))
        fi

        sug_draw_widget "$(sug_get_active_candidate)"
    else
        sug_refresh
    fi

    return 0
}

# Accepts the active candidate and inserts it into the readline buffer.
# @return 0 Always.
sug_accept() {
    local sug_acc_candidate
    local sug_acc_prefix
    local sug_acc_suffix

    (( SUG_CANDIDATE_COUNT > 0 )) || return 0

    sug_detect_token "$READLINE_LINE" "$READLINE_POINT"
    sug_acc_candidate=$(sug_get_active_candidate)
    [[ -n $sug_acc_candidate ]] || return 0

    sug_acc_prefix=${READLINE_LINE:0:SUG_TOKEN_START}
    sug_acc_suffix=${READLINE_LINE:SUG_TOKEN_END}

    READLINE_LINE="${sug_acc_prefix}${sug_acc_candidate}${sug_acc_suffix}"
    READLINE_POINT=$((SUG_TOKEN_START + ${#sug_acc_candidate}))
    SUG_CANDIDATES=()
    SUG_CANDIDATE_COUNT=0
    SUG_ACTIVE_INDEX=0
    sug_toggle_tab "native"
    sug_clear_widget
    return 0
}

# Simulates self-insertion of a character and refreshes suggestions.
# @param $1 Character to insert.
# @return 0 Always.
sug_self_insert() {
    local sug_si_char="$1"
    local sug_si_prefix=${READLINE_LINE:0:READLINE_POINT}
    local sug_si_suffix=${READLINE_LINE:READLINE_POINT}

    READLINE_LINE="${sug_si_prefix}${sug_si_char}${sug_si_suffix}"
    READLINE_POINT=$((READLINE_POINT + ${#sug_si_char}))
    sug_refresh
    return 0
}

# Deletes a character before the cursor and refreshes suggestions.
# @return 0 Always.
sug_backward_delete() {
    local sug_bd_prefix
    local sug_bd_suffix

    if (( READLINE_POINT > 0 )); then
        sug_bd_prefix=${READLINE_LINE:0:READLINE_POINT-1}
        sug_bd_suffix=${READLINE_LINE:READLINE_POINT}
        READLINE_LINE="${sug_bd_prefix}${sug_bd_suffix}"
        ((READLINE_POINT--))
    fi

    sug_refresh
    return 0
}

# Deletes the character at the cursor and refreshes suggestions.
# @return 0 Always.
sug_delete_char() {
    local sug_dc_prefix
    local sug_dc_suffix

    if (( READLINE_POINT < ${#READLINE_LINE} )); then
        sug_dc_prefix=${READLINE_LINE:0:READLINE_POINT}
        sug_dc_suffix=${READLINE_LINE:READLINE_POINT+1}
        READLINE_LINE="${sug_dc_prefix}${sug_dc_suffix}"
    fi

    sug_refresh
    return 0
}

# Moves the cursor backward and refreshes suggestions.
# @return 0 Always.
sug_backward_char() {
    (( READLINE_POINT > 0 )) && ((READLINE_POINT--))
    sug_refresh
    return 0
}

# Moves the cursor forward and refreshes suggestions.
# @return 0 Always.
sug_forward_char() {
    (( READLINE_POINT < ${#READLINE_LINE} )) && ((READLINE_POINT++))
    sug_refresh
    return 0
}

# Moves the cursor to the beginning of the line and refreshes suggestions.
# @return 0 Always.
sug_beginning_of_line() {
    READLINE_POINT=0
    sug_refresh
    return 0
}

# Moves the cursor to the end of the line and refreshes suggestions.
# @return 0 Always.
sug_end_of_line() {
    READLINE_POINT=${#READLINE_LINE}
    sug_refresh
    return 0
}

# Hook executed by PROMPT_COMMAND to clear the widget.
# @return 0 Always.
sug_prompt_hook() {
    SUG_CANCELLED_LINE=''
    SUG_CANCELLED_POINT=''
    SUG_CANDIDATES=()
    SUG_CANDIDATE_COUNT=0
    SUG_ACTIVE_INDEX=0
    sug_toggle_tab "native"
    sug_clear_widget
    return 0
}

# Installs the prompt hook into PROMPT_COMMAND.
# @return 0 Always.
sug_install_prompt_hook() {
    local hook='sug_prompt_hook'

    case ";${PROMPT_COMMAND:-};" in
        *";${hook};"*)
            return 0
            ;;
    esac

    if [[ -n ${PROMPT_COMMAND:-} ]]; then
        PROMPT_COMMAND="${hook};${PROMPT_COMMAND}"
    else
        PROMPT_COMMAND="$hook"
    fi

    return 0
}

# Binds a key to a shell command using bind -x.
# @param $1 Key sequence.
# @param $2 Command to execute.
# @return 0 Always.
sug_bind_shell() {
    local sug_bs_key="$1"
    local sug_bs_cmd="$2"

    bind -x "\"${sug_bs_key}\":\"${sug_bs_cmd}\""
}

# Binds all printable characters to sug_self_insert.
# @return 0 Always.
sug_bind_printable() {
    local sug_bp_code=32
    local sug_bp_octal
    local sug_bp_char
    local sug_bp_quoted

    while (( sug_bp_code <= 126 )); do
        printf -v sug_bp_octal '\\%03o' "$sug_bp_code"
        printf -v sug_bp_char '%b' "$sug_bp_octal"
        printf -v sug_bp_quoted '%q' "$sug_bp_char"
        sug_bind_shell "$sug_bp_octal" "sug_self_insert ${sug_bp_quoted}"
        ((sug_bp_code++))
    done

    return 0
}

# Installs all required readline bindings.
# @return 0 Always.
sug_install_bindings() {
    sug_bind_printable
    bind 'set bind-tty-special-chars off'
    sug_bind_shell '\C-?' 'sug_backward_delete'
    sug_bind_shell '\C-h' 'sug_backward_delete'
    sug_bind_shell '\e[3~' 'sug_delete_char'
    sug_bind_shell '\e[D' 'sug_backward_char'
    sug_bind_shell '\e[C' 'sug_forward_char'
    sug_bind_shell '\eOD' 'sug_backward_char'
    sug_bind_shell '\eOC' 'sug_forward_char'
    bind -x '"\C-a":"sug_beginning_of_line"'
    bind -x '"\C-e":"sug_end_of_line"'
    sug_toggle_tab "native"
    sug_bind_shell '\e' 'sug_cancel'
    sug_bind_shell '\e[1;5A' 'sug_prev'
    sug_bind_shell '\e[1;5B' 'sug_next'
    sug_bind_shell '\e[5A' 'sug_prev'
    sug_bind_shell '\e[5B' 'sug_next'
    return 0
}

# Enables the autosuggestion system.
# @return 0 on success, 1 on failure.
sug_enable() {
    [[ -n ${BASH_VERSION:-} ]] || {
        sug_fail 'sug.sh requires interactive bash.'
        return 1
    }

    case $- in
        *i*) ;;
        *)
            sug_fail 'sug.sh requires interactive shell.'
            return 1
            ;;
    esac

    if [[ ${SUG_ENABLED:-0} == '1' ]]; then
        sug_disable
    fi

    sug_validate_config || return 1
    sug_capture_bindings || {
        sug_fail 'Unable to capture current readline bindings.'
        return 1
    }

    sug_load_map || return 1
    sug_reset_state
    SUG_ENABLED=1

    SUG_ORIGINAL_TAB_CMD=$(bind -p | awk -F': ' '/"\\C-i"/ {print $2; exit}')
    [[ $SUG_ORIGINAL_TAB_CMD == '"sug_accept"' ]] && SUG_ORIGINAL_TAB_CMD=''
    [[ -n $SUG_ORIGINAL_TAB_CMD ]] || SUG_ORIGINAL_TAB_CMD='complete'

    sug_install_prompt_hook
    sug_install_exit_hook
    sug_install_bindings
    return 0
}

# Disables the autosuggestion system.
# @return 0 Always.
sug_disable() {
    SUG_ENABLED=0
    sug_remove_prompt_hook
    sug_restore_exit_hook
    sug_restore_bindings
    sug_cleanup_temp_files
    SUG_ORIGINAL_TAB_CMD=''
    sug_reset_state
    sug_clear_widget
    return 0
}

# Main entry point for the script.
# @return 0 on success, 1 on failure.
main() {
    if ! sug_is_sourced; then
        sug_fail 'Source this file from interactive bash.'
        exit 1
    fi

    sug_set_defaults
    sug_parse_args "$@" || return "$?"
    sug_enable || return 1
    return 0
}

main "$@"
