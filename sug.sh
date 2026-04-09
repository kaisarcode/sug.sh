#!/bin/sh
# sug.sh - Shell token autosuggestion integration layer
# Summary: Adds readline-aware token prediction to interactive bash.
# Author:  KaisarCode
# Website: https://kaisarcode.com
# License: https://www.gnu.org/licenses/gpl-3.0.html
# shellcheck disable=SC2086

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
    if [ -n "${BASH_SOURCE:-}" ]; then
        if [ "$BASH_SOURCE" != "$0" ]; then
            return 0
        fi
    fi

    case "${0##*/}" in
        sh|dash|bash|rbash|ash|ksh|mksh|zsh|-sh|-dash|-bash|-rbash|-ash|-ksh|-mksh|-zsh)
            return 0
            ;;
    esac

    return 1
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
    SUG_MAPS=""
    [ -n "${SUG_LIMIT:-}" ] || SUG_LIMIT='8'
    [ -n "${SUG_THRESHOLD:-}" ] || SUG_THRESHOLD='0.3'
    [ -n "${SUG_MIN:-}" ] || SUG_MIN='3'
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
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -m|--map)
                [ "$#" -ge 2 ] || {
                    sug_fail 'Missing value for -m|--map.'
                    return 1
                }
                SUG_MAPS="${SUG_MAPS}${SUG_MAPS:+ }$2"
                shift 2
                ;;
            -n|--limit)
                [ "$#" -ge 2 ] || {
                    sug_fail 'Missing value for -n|--limit.'
                    return 1
                }
                sug_validate_number '-n|--limit' "$2" || return 1
                SUG_LIMIT="$2"
                shift 2
                ;;
            -t|--threshold)
                [ "$#" -ge 2 ] || {
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
    [ -n "$SUG_MAPS" ] || {
        sug_fail 'Missing required map. Use -m|--map PATH.'
        return 1
    }

    set -- $SUG_MAPS
    for sug_vc_map do
        [ -f "$sug_vc_map" ] || {
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
    SUG_CANDIDATE_FILE=''
    SUG_CANDIDATE_COUNT=0
    SUG_TAB_MODE=''
    return 0
}

# Toggles the Tab key binding between suggestion accept and native completion.
# @param $1 Target mode ('suggest' or 'native').
# @return 0 Always.
sug_toggle_tab() {
    sug_tt_target="$1"
    [ "$SUG_TAB_MODE" = "$sug_tt_target" ] && return 0

    if [ "$sug_tt_target" = "suggest" ]; then
        bind -x '"\C-i": "sug_accept"'
    else
        bind "\"\C-i\": ${SUG_ORIGINAL_TAB_CMD:-complete}"
    fi

    SUG_TAB_MODE="$sug_tt_target"
    return 0
}

# Checks if the script is running in a valid TTY.
# @return 0 if it has a TTY, 1 otherwise.
sug_has_tty() {
    [ -t 1 ] && [ -n "$TERM" ] && [ "$TERM" != 'dumb' ]
}

# Checks if a character is a token separator.
# @param $1 Character to check.
# @return 0 if it is a separator, 1 otherwise.
sug_is_separator() {
    case "$1" in
        '' | [[:space:]] | ';'|'|'|'&'|'<'|'>'|'(' | ')' | '{' | '}' \
        | '[' | ']' | '=' | ':' | ',' | '"' | "'" | "\\")
            return 0
            ;;
    esac

    return 1
}

# Detects the token at the current cursor position in the buffer.
# @param $1 Buffer string.
# @param $2 Cursor point.
# @return 0 Always.
sug_detect_token() {
    sug_dt_buffer="$1"
    sug_dt_point="$2"
    sug_dt_length="${#sug_dt_buffer}"
    sug_dt_char=''

    [ "$sug_dt_point" -gt "$sug_dt_length" ] && sug_dt_point="$sug_dt_length"

    SUG_TOKEN_START="$sug_dt_point"
    while [ "$SUG_TOKEN_START" -gt 0 ]; do
        sug_dt_char=$(printf '%s' "$sug_dt_buffer" | cut -c "$SUG_TOKEN_START")
        sug_is_separator "$sug_dt_char" && break
        SUG_TOKEN_START=$((SUG_TOKEN_START - 1))
    done

    SUG_TOKEN_END="$sug_dt_point"
    while [ "$SUG_TOKEN_END" -lt "$sug_dt_length" ]; do
        sug_dt_char=$(printf '%s' "$sug_dt_buffer" | cut -c "$((SUG_TOKEN_END + 1))")
        sug_is_separator "$sug_dt_char" && break
        SUG_TOKEN_END=$((SUG_TOKEN_END + 1))
    done

    if [ "$((SUG_TOKEN_START + 1))" -le "$SUG_TOKEN_END" ]; then
        SUG_TOKEN_TEXT=$(printf '%s' "$sug_dt_buffer" | cut -c "$((SUG_TOKEN_START + 1))-$SUG_TOKEN_END")
    else
        SUG_TOKEN_TEXT=''
    fi
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
    sug_dw_text="$1"

    sug_has_tty || return 0

    if [ -z "$sug_dw_text" ]; then
        sug_clear_widget
        return 0
    fi

    if [ "${SUG_WIDGET_VISIBLE:-0}" = '1' ] \
    && [ "$sug_dw_text" = "${SUG_LAST_WIDGET_TEXT:-}" ]; then
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
    [ -n "${SUG_CANDIDATE_FILE:-}" ] && : > "$SUG_CANDIDATE_FILE"
    SUG_CANDIDATE_COUNT=0
    SUG_ACTIVE_INDEX=0
    sug_clear_widget
    return 0
}

# Checks if the current state matches the last cancelled state.
# @return 0 if cancelled state matches, 1 otherwise.
sug_is_cancelled_state() {
    [ "$READLINE_LINE" = "$SUG_CANCELLED_LINE" ] \
    && [ "$READLINE_POINT" = "$SUG_CANCELLED_POINT" ]
}

# Loads the candidate map from the specified file.
# @return 0 Always.
sug_load_map() {
    [ -n "${SUG_TOKEN_FILE:-}" ] && rm -f "$SUG_TOKEN_FILE"
    SUG_TOKEN_FILE="$(mktemp)"

    sort $SUG_MAPS | uniq -c | sort -rn \
    | sed 's/^[[:space:]]*//' > "$SUG_TOKEN_FILE"

    return 0
}

# Finds candidates that match the given token.
# @param $1 Token to match.
# @return 0 Always.
sug_match_token() {
    sug_mt_token="$1"

    [ -n "${SUG_CANDIDATE_FILE:-}" ] && rm -f "$SUG_CANDIDATE_FILE"
    SUG_CANDIDATE_FILE="$(mktemp)"
    SUG_CANDIDATE_COUNT=0
    SUG_ACTIVE_INDEX=0

    [ -n "$sug_mt_token" ] || return 0

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
    ' "$SUG_TOKEN_FILE" | sort -rn | head -n "$SUG_LIMIT" | cut -f2- > "$SUG_CANDIDATE_FILE"

    SUG_CANDIDATE_COUNT=$(wc -l < "$SUG_CANDIDATE_FILE")
    return 0
}

# Refreshes the suggestion based on the current readline state.
# @return 0 Always.
sug_refresh() {
    sug_re_candidate=''

    [ "${SUG_ENABLED:-0}" = '1' ] || return 0

    if sug_is_cancelled_state; then
        SUG_CANDIDATE_COUNT=0
        SUG_ACTIVE_INDEX=0
        sug_toggle_tab "native"
        sug_clear_widget
        return 0
    fi

    SUG_CANCELLED_LINE=''
    SUG_CANCELLED_POINT=''

    sug_detect_token "$READLINE_LINE" "$READLINE_POINT"

    if [ -z "$SUG_TOKEN_TEXT" ]; then
        SUG_CANDIDATE_COUNT=0
        SUG_ACTIVE_INDEX=0
        sug_toggle_tab "native"
        sug_clear_widget
        return 0
    fi

    if [ "${#SUG_TOKEN_TEXT}" -lt "$SUG_MIN" ]; then
        SUG_CANDIDATE_COUNT=0
        SUG_ACTIVE_INDEX=0
        sug_toggle_tab "native"
        sug_clear_widget
        return 0
    fi

    sug_match_token "$SUG_TOKEN_TEXT"

    if [ "$SUG_CANDIDATE_COUNT" -eq 0 ]; then
        sug_toggle_tab "native"
        sug_clear_widget
        return 0
    fi

    [ "$SUG_ACTIVE_INDEX" -ge "$SUG_CANDIDATE_COUNT" ] && SUG_ACTIVE_INDEX=0

    sug_re_candidate=$(sed -n "$((SUG_ACTIVE_INDEX + 1))p" "$SUG_CANDIDATE_FILE")

    if [ -z "$sug_re_candidate" ]; then
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
    if [ "$SUG_CANDIDATE_COUNT" -gt 0 ]; then
        if [ "$SUG_ACTIVE_INDEX" -lt $((SUG_CANDIDATE_COUNT - 1)) ]; then
            SUG_ACTIVE_INDEX=$((SUG_ACTIVE_INDEX + 1))
        else
            SUG_ACTIVE_INDEX=0
        fi

        sug_draw_widget "$(sed -n "$((SUG_ACTIVE_INDEX + 1))p" "$SUG_CANDIDATE_FILE")"
    else
        sug_refresh
    fi
    return 0
}

# Moves to the previous candidate in the list.
# @return 0 Always.
sug_prev() {
    if [ "$SUG_CANDIDATE_COUNT" -gt 0 ]; then
        if [ "$SUG_ACTIVE_INDEX" -gt 0 ]; then
            SUG_ACTIVE_INDEX=$((SUG_ACTIVE_INDEX - 1))
        else
            SUG_ACTIVE_INDEX=$((SUG_CANDIDATE_COUNT - 1))
        fi

        sug_draw_widget "$(sed -n "$((SUG_ACTIVE_INDEX + 1))p" "$SUG_CANDIDATE_FILE")"
    else
        sug_refresh
    fi
    return 0
}

# Accepts the active candidate and inserts it into the readline buffer.
# @return 0 Always.
sug_accept() {
    sug_acc_candidate=''
    sug_acc_prefix=''
    sug_acc_suffix=''

    [ "$SUG_CANDIDATE_COUNT" -gt 0 ] || return 0

    sug_detect_token "$READLINE_LINE" "$READLINE_POINT"
    sug_acc_candidate=$(sed -n "$((SUG_ACTIVE_INDEX + 1))p" "$SUG_CANDIDATE_FILE")
    
    if [ "$SUG_TOKEN_START" -gt 0 ]; then
        sug_acc_prefix=$(printf '%s' "$READLINE_LINE" | cut -c "1-$SUG_TOKEN_START")
    else
        sug_acc_prefix=''
    fi
    
    if [ "$((SUG_TOKEN_END + 1))" -le "${#READLINE_LINE}" ]; then
        sug_acc_suffix=$(printf '%s' "$READLINE_LINE" | cut -c "$((SUG_TOKEN_END + 1))-")
    else
        sug_acc_suffix=''
    fi
    
    READLINE_LINE="${sug_acc_prefix}${sug_acc_candidate}${sug_acc_suffix}"
    READLINE_POINT=$((SUG_TOKEN_START + ${#sug_acc_candidate}))
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
    sug_si_char="$1"
    if [ "$READLINE_POINT" -gt 0 ]; then
        sug_si_prefix=$(printf '%s' "$READLINE_LINE" | cut -c "1-$READLINE_POINT")
    else
        sug_si_prefix=''
    fi
    
    if [ "$((READLINE_POINT + 1))" -le "${#READLINE_LINE}" ]; then
        sug_si_suffix=$(printf '%s' "$READLINE_LINE" | cut -c "$((READLINE_POINT + 1))-")
    else
        sug_si_suffix=''
    fi

    READLINE_LINE="${sug_si_prefix}${sug_si_char}${sug_si_suffix}"
    READLINE_POINT=$((READLINE_POINT + ${#sug_si_char}))
    sug_refresh
    return 0
}

# Deletes a character before the cursor and refreshes suggestions.
# @return 0 Always.
sug_backward_delete() {
    if [ "$READLINE_POINT" -gt 0 ]; then
        if [ "$((READLINE_POINT - 1))" -gt 0 ]; then
            sug_bd_prefix=$(printf '%s' "$READLINE_LINE" | cut -c "1-$((READLINE_POINT - 1))")
        else
            sug_bd_prefix=''
        fi
        
        if [ "$((READLINE_POINT + 1))" -le "${#READLINE_LINE}" ]; then
            sug_bd_suffix=$(printf '%s' "$READLINE_LINE" | cut -c "$((READLINE_POINT + 1))-")
        else
            sug_bd_suffix=''
        fi
        
        READLINE_LINE="${sug_bd_prefix}${sug_bd_suffix}"
        READLINE_POINT=$((READLINE_POINT - 1))
        sug_refresh
    else
        sug_refresh
    fi
    return 0
}

# Deletes the character at the cursor and refreshes suggestions.
# @return 0 Always.
sug_delete_char() {
    if [ "$READLINE_POINT" -lt "${#READLINE_LINE}" ]; then
        if [ "$READLINE_POINT" -gt 0 ]; then
            sug_dc_prefix=$(printf '%s' "$READLINE_LINE" | cut -c "1-$READLINE_POINT")
        else
            sug_dc_prefix=''
        fi
        
        if [ "$((READLINE_POINT + 2))" -le "${#READLINE_LINE}" ]; then
            sug_dc_suffix=$(printf '%s' "$READLINE_LINE" | cut -c "$((READLINE_POINT + 2))-")
        else
            sug_dc_suffix=''
        fi
        
        READLINE_LINE="${sug_dc_prefix}${sug_dc_suffix}"
        sug_refresh
    else
        sug_refresh
    fi
    return 0
}

# Moves the cursor backward and refreshes suggestions.
# @return 0 Always.
sug_backward_char() {
    [ "$READLINE_POINT" -gt 0 ] && READLINE_POINT=$((READLINE_POINT - 1))
    sug_refresh
    return 0
}

# Moves the cursor forward and refreshes suggestions.
# @return 0 Always.
sug_forward_char() {
    [ "$READLINE_POINT" -lt "${#READLINE_LINE}" ] \
    && READLINE_POINT=$((READLINE_POINT + 1))
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
    READLINE_POINT="${#READLINE_LINE}"
    sug_refresh
    return 0
}

# Hook executed by PROMPT_COMMAND to clear the widget.
# @return 0 Always.
sug_prompt_hook() {
    sug_clear_widget
    return 0
}

# Installs the prompt hook into PROMPT_COMMAND.
# @return 0 Always.
sug_install_prompt_hook() {
    case ";${PROMPT_COMMAND:-};" in
        *';sug_prompt_hook;'*)
            return 0
            ;;
    esac

    if [ -n "${PROMPT_COMMAND:-}" ]; then
        PROMPT_COMMAND="sug_prompt_hook;${PROMPT_COMMAND}"
    else
        PROMPT_COMMAND='sug_prompt_hook'
    fi

    return 0
}

# Binds a key to a shell command using bind -x.
# @param $1 Key sequence.
# @param $2 Command to execute.
# @return 0 Always.
sug_bind_shell() {
    sug_bs_key="$1"
    sug_bs_cmd="$2"

    bind -x "\"${sug_bs_key}\":\"${sug_bs_cmd}\""
}

# Binds all printable characters to sug_self_insert.
# @return 0 Always.
sug_bind_printable() {
    sug_bp_code=32

    while [ "$sug_bp_code" -le 126 ]; do
        sug_bp_octal=$(printf '\\%03o' "$sug_bp_code")
        sug_bp_char=$(printf "%b" "$sug_bp_octal")
        sug_bp_quoted="'$sug_bp_char'"
        [ "$sug_bp_char" = "'" ] && sug_bp_quoted="\"'\""
        sug_bind_shell "$sug_bp_octal" "sug_self_insert $sug_bp_quoted"
        sug_bp_code=$((sug_bp_code + 1))
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
    bind -x '"\C-a": "sug_beginning_of_line"'
    bind -x '"\C-e": "sug_end_of_line"'
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
    if [ -z "${BASH_VERSION:-}" ]; then
        sug_fail 'sug.sh requires interactive bash for its current implementation.'
        return 1
    fi

    case $- in
        *i*) ;;
        *)
            sug_fail 'sug.sh requires interactive shell.'
            return 1
            ;;
    esac

    sug_validate_config || return 1
    sug_load_map || return 1
    sug_reset_state
    SUG_ENABLED=1
    
    SUG_ORIGINAL_TAB_CMD=$(bind -p | grep '"\C-i"' | sed 's/.*: //')
    [ "$SUG_ORIGINAL_TAB_CMD" = '"sug_accept"' ] && SUG_ORIGINAL_TAB_CMD=""
    [ -n "$SUG_ORIGINAL_TAB_CMD" ] || SUG_ORIGINAL_TAB_CMD='complete'

    sug_install_prompt_hook
    sug_install_bindings
    return 0
}

# Disables the autosuggestion system.
# @return 0 Always.
sug_disable() {
    SUG_ENABLED=0
    [ -n "${SUG_TOKEN_FILE:-}" ] && rm -f "$SUG_TOKEN_FILE"
    [ -n "${SUG_CANDIDATE_FILE:-}" ] && rm -f "$SUG_CANDIDATE_FILE"
    SUG_TOKEN_FILE=''
    SUG_CANDIDATE_FILE=''
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
