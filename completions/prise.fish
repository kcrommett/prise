# Fish completion for prise

# Disable file completions by default
complete -c prise -f

# Top-level commands
complete -c prise -n __fish_use_subcommand -a serve -d 'Start the server in the foreground'
complete -c prise -n __fish_use_subcommand -a session -d 'Manage sessions'
complete -c prise -n __fish_use_subcommand -a pty -d 'Manage PTYs'
complete -c prise -n __fish_use_subcommand -s h -l help -d 'Show help message'
complete -c prise -n __fish_use_subcommand -s v -l version -d 'Show version'

# Session subcommands
complete -c prise -n '__fish_seen_subcommand_from session; and not __fish_seen_subcommand_from attach list rename delete' -a attach -d 'Attach to a session'
complete -c prise -n '__fish_seen_subcommand_from session; and not __fish_seen_subcommand_from attach list rename delete' -a list -d 'List all sessions'
complete -c prise -n '__fish_seen_subcommand_from session; and not __fish_seen_subcommand_from attach list rename delete' -a rename -d 'Rename a session'
complete -c prise -n '__fish_seen_subcommand_from session; and not __fish_seen_subcommand_from attach list rename delete' -a delete -d 'Delete a session'
complete -c prise -n '__fish_seen_subcommand_from session; and not __fish_seen_subcommand_from attach list rename delete' -s h -l help -d 'Show session help'

# PTY subcommands
complete -c prise -n '__fish_seen_subcommand_from pty; and not __fish_seen_subcommand_from list kill' -a list -d 'List all PTYs'
complete -c prise -n '__fish_seen_subcommand_from pty; and not __fish_seen_subcommand_from list kill' -a kill -d 'Kill a PTY by ID'
complete -c prise -n '__fish_seen_subcommand_from pty; and not __fish_seen_subcommand_from list kill' -s h -l help -d 'Show PTY help'

# Dynamic session name completion
function __prise_sessions
    prise session list 2>/dev/null | string match -r '^\S+'
end

complete -c prise -n '__fish_seen_subcommand_from session; and __fish_seen_subcommand_from attach' -a '(__prise_sessions)' -d Session
complete -c prise -n '__fish_seen_subcommand_from session; and __fish_seen_subcommand_from delete' -a '(__prise_sessions)' -d Session
complete -c prise -n '__fish_seen_subcommand_from session; and __fish_seen_subcommand_from rename' -a '(__prise_sessions)' -d Session

# Dynamic PTY ID completion
function __prise_pty_ids
    prise pty list 2>/dev/null | string match -r '^\d+'
end

complete -c prise -n '__fish_seen_subcommand_from pty; and __fish_seen_subcommand_from kill' -a '(__prise_pty_ids)' -d 'PTY ID'
