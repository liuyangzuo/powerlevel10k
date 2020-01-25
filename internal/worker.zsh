# invoked in worker: _p9k_worker_main <pgid>
function _p9k_worker_main() {
  local pgid=$1

  mkfifo $_p9k__worker_file_prefix.fifo || return
  echo -nE - s${1}$'\x1e'               || return
  exec 0<$_p9k__worker_file_prefix.fifo || return
  rm $_p9k__worker_file_prefix.fifo     || return

  typeset -g IFS=$' \t\n\0'

  local -i reset
  local req fd
  local -a ready
  local _p9k_worker_request_id
  local -A _p9k_worker_fds       # fd => id$'\x1f'callback
  local -A _p9k_worker_inflight  # id => inflight count

  function _p9k_worker_reply_begin() { print -nr -- e }
  function _p9k_worker_reply_end()   { print -nr -- $'\x1e' }
  function _p9k_worker_reply()       { print -nr -- e${(pj:\n:)@}$'\x1e' }

  # usage: _p9k_worker_async <work> <callback>
  function _p9k_worker_async() {
    local fd async=$1
    sysopen -r -o cloexec -u fd <(
      () { eval $async; } && print -n '\x1e') || return
    (( ++_p9k_worker_inflight[$_p9k_worker_request_id] ))
    _p9k_worker_fds[$fd]=$_p9k_worker_request_id$'\x1f'$2
  }

  {
    while zselect -a ready 0 ${(k)_p9k_worker_fds}; do
      [[ $ready[1] == -r ]] || return
      for fd in ${ready:1}; do
        if [[ $fd == 0 ]]; then
          local buf=
          while true; do
            sysread -t 0 'buf[$#buf+1]'  && continue
            (( $? == 4 ))                || return
            [[ $buf[-1] == (|$'\x1e') ]] && break
            sysread 'buf[$#buf+1]'       || return
          done
          for req in ${(ps:\x1e:)buf}; do
            _p9k_worker_request_id=${req%%$'\x1f'*}
            () { eval $req[$#_p9k_worker_request_id+2,-1] }
            (( $+_p9k_worker_inflight[$_p9k_worker_request_id] )) && continue
            print -rn -- d$_p9k_worker_request_id$'\x1e' || return
          done
        else
          local REPLY=
          while true; do
            sysread -i $fd 'REPLY[$#REPLY+1]' && continue
            (( $? == 5 ))                     || return
            break
          done
          local cb=$_p9k_worker_fds[$fd]
          _p9k_worker_request_id=${cb%%$'\x1f'*}
          unset "_p9k_worker_fds[$fd]"
          exec {fd}>&-
          if [[ $REPLY == *$'\x1e' ]]; then
            REPLY[-1]=""
            () { eval $cb[$#_p9k_worker_request_id+2,-1] }
          fi
          if (( --_p9k_worker_inflight[$_p9k_worker_request_id] == 0 )); then
            unset "_p9k_worker_inflight[$_p9k_worker_request_id]"
            print -rn -- d$_p9k_worker_request_id$'\x1e' || return
          fi
        fi
      done
    done
  } always {
    kill -- -$pgid
  }
}

typeset -g   _p9k__worker_pid
typeset -g   _p9k__worker_req_fd
typeset -g   _p9k__worker_resp_fd
typeset -g   _p9k__worker_shell_pid
typeset -g   _p9k__worker_file_prefix
typeset -gA  _p9k__worker_request_map

# invoked in master: _p9k_worker_invoke <request-id> <list>
function _p9k_worker_invoke() {
  [[ -n $_p9k__worker_resp_fd ]] || return
  local req=$1$'\x1f'$2$'\x1e'
  if [[ -n $_p9k__worker_req_fd && $+_p9k__worker_request_map[$1] == 0 ]]; then
    _p9k__worker_request_map[$1]=
    print -rnu $_p9k__worker_req_fd -- $req
  else
    _p9k__worker_request_map[$1]=$req
  fi
}

function _p9k_worker_cleanup() {
  emulate -L zsh
  setopt no_hist_expand extended_glob no_prompt_bang prompt_{percent,subst} no_aliases
  [[ $_p9k__worker_shell_pid == $sysparams[pid] ]] && _p9k_worker_stop
  return 0
}

function _p9k_worker_stop() {
  emulate -L zsh
  setopt no_hist_expand extended_glob no_prompt_bang prompt_{percent,subst} no_aliases
  add-zsh-hook -D zshexit _p9k_worker_cleanup
  [[ -n $_p9k__worker_resp_fd     ]] && zle -F $_p9k__worker_resp_fd
  [[ -n $_p9k__worker_resp_fd     ]] && exec {_p9k__worker_resp_fd}>&-
  [[ -n $_p9k__worker_req_fd      ]] && exec {_p9k__worker_req_fd}>&-
  [[ -n $_p9k__worker_pid         ]] && kill -- -$_p9k__worker_pid 2>/dev/null
  _p9k__worker_pid=
  _p9k__worker_req_fd=
  _p9k__worker_resp_fd=
  _p9k__worker_shell_pid=
  _p9k__worker_request_map=()
  return 0
}

function _p9k_worker_receive() {
  emulate -L zsh
  setopt no_hist_expand extended_glob no_prompt_bang prompt_{percent,subst} no_aliases

  {
    (( $# <= 1 )) || return

    local buf resp
    while true; do
      sysread -t 0 -i $_p9k__worker_resp_fd 'buf[$#buf+1]' && continue
      (( $? == 4 ))                                                                   || return
      [[ $buf == (|*$'\x1e')$'\x05'# ]] && break
      sysread -i $_p9k__worker_resp_fd 'buf[$#buf+1]'                                 || return
    done

    local -i reset
    for resp in ${(ps:\x1e:)${buf//$'\x05'}}; do
      local arg=$resp[2,-1]
      case $resp[1] in
        d)
          local req=$_p9k__worker_request_map[$arg]
          if [[ -n $req ]]; then
            _p9k__worker_request_map[$arg]=
            print -rnu $_p9k__worker_req_fd -- $req                                   || return
          else
            unset "_p9k__worker_request_map[$arg]"
          fi
        ;;
        e)
          if (( start_time )); then
            local -F end_time=EPOCHREALTIME
            local -F3 latency=$((1000*(end_time-start_time)))
            echo "latency: $latency ms" >>/tmp/log
            start_time=0
          fi
          () { eval $arg }
        ;;
        s)
          [[ -z $_p9k__worker_pid ]]                                                  || return
          [[ $arg == <1->        ]]                                                   || return
          _p9k__worker_pid=$arg
          sysopen -w -o cloexec -u _p9k__worker_req_fd $_p9k__worker_file_prefix.fifo || return
          local req=
          for req in $_p9k__worker_request_map; do
            print -rnu $_p9k__worker_req_fd -- $req                                   || return
          done
          _p9k__worker_request_map=({${(k)^_p9k__worker_request_map},''})
        ;;
        *)
          return 1
        ;;
      esac
    done

    if (( reset == 2 )); then
      _p9k_refresh_reason=worker
      _p9k_set_prompt
      _p9k_refresh_reason=''
    fi
    (( reset )) && _p9k_reset_prompt
    return 0
  } always {
    (( $? )) && _p9k_worker_stop
  }
}

function _p9k_worker_start() {
  setopt no_bgnice monitor
  {
    [[ -n $_p9k__worker_resp_fd ]] && return
    _p9k__worker_file_prefix=${TMPDIR:-/tmp}/p10k.worker.$EUID.$$.$EPOCHSECONDS

    sysopen -r -o cloexec -u _p9k__worker_resp_fd <(
      if [[ -n $_POWERLEVEL9K_WORKER_LOG_LEVEL ]]; then
        exec 2>$_p9k__worker_file_prefix.log
        setopt xtrace
      else
        exec 2>/dev/null
      fi
      # todo: remove
      exec 2>>/tmp/log
      setopt xtrace
      zmodload zsh/zselect               || return
      ! { zselect -t0 || (( $? != 1 )) } || return
      local pgid=$sysparams[pid]
      _p9k_worker_main $pgid &
      {
        trap '' PIPE
        while syswrite $'\x05'; do zselect -t 1000; done
        kill -- -$pgid
      } &
      exec =true) || return
    zle -F $_p9k__worker_resp_fd _p9k_worker_receive
    _p9k__worker_shell_pid=$sysparams[pid]
    add-zsh-hook zshexit _p9k_worker_cleanup
  } always {
    (( $? )) && _p9k_worker_stop
  }
}

# todo: remove

return

function _p9k_reset_prompt() {
  zle && zle reset-prompt && zle -R
}

emulate -L zsh -o prompt_subst -o interactive_comments # -o xtrace

# POWERLEVEL9K_WORKER_LOG_LEVEL=DEBUG

zmodload zsh/datetime
zmodload zsh/system
autoload -Uz add-zsh-hook

function foo_compute() {
  _p9k_worker_reply 'echo sync latency: $((1000*(EPOCHREALTIME-'$1'))) >>/tmp/log'
  _p9k_worker_async foo_async "foo_sync $1"
}

function foo_async() {
}

function foo_sync() {
  _p9k_worker_reply 'echo async latency: $((1000*(EPOCHREALTIME-'$1'))) >>/tmp/log'
}

typeset -F start_time=EPOCHREALTIME
_p9k_worker_start
_p9k_worker_invoke first '_p9k_worker_reply ""'
echo -E - $((1000*(EPOCHREALTIME-start_time)))

bm() { _p9k_worker_invoke foo$1 "foo_compute $EPOCHREALTIME" }
