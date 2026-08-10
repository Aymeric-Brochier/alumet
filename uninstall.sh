#!/bin/sh
set -e

usage() {
  this=$1
  cat <<EOF
$this: remove alumet-agent installed from ${OWNER}/${REPO}

Usage: $this [-v] [-l] [-r <release>]
  -v turns on verbose logging
  -l remove alumet-agent locally (to ~/.local/bin).
EOF
  exit 2
}
parse_args() {
  while getopts "vh?xl" arg; do
    case "$arg" in
      v) log_set_priority 10 ;;
      h | \?) usage "$0" ;;
      x) set -x ;;
      l) LOCAL="local";;
    esac
  done
}
remove_local() {

  if [ ! -d "${HOME}/.local/bin" ]; then
    log_info "directory ${HOME}/.local/bin not found"
    log_info "You may have not installed alumet with the install script locally"
    log_info "Or you may have already uninstalled it"
  else
    if [ ! -f "${HOME}/.local/bin/alumet-agent-local" ]; then
      log_info "file ${HOME}/.local/bin/alumet-agent-local not found"
      log_info "You may have not installed alumet with the install script locally"
      log_info "Or you may have already uninstalled it"
    else
      rm "${HOME}/.local/bin/alumet-agent-local"
      log_info "Removed local Alumet successfully"
    fi

  fi
}
execute() {

  if test "$LOCAL"; then
    log_info "trying to remove locally from ~/.local/bin"
    remove_local
  else
    case $DISTRIB in
      ubuntu|debian) sudo apt-get remove -y alumet-agent  ;;
      fc|ubi) sudo yum remove -y alumet-agent ;;
      *) log_info "unknown distrib" ;;
    esac
    log_info "Removed Alumet successfully"
  fi

}
log_prefix() {
	echo "$PREFIX"
}

cat /dev/null <<EOF
------------------------------------------------------------------------
https://github.com/client9/shlib - portable posix shell functions
Public domain - http://unlicense.org
https://github.com/client9/shlib/blob/HEAD/LICENSE.md
but credit (and pull requests) appreciated.
------------------------------------------------------------------------
EOF
is_command() {
  command -v "$1" >/dev/null
}
echoerr() {
  echo "$@" 1>&2
}
_logp=6
log_set_priority() {
  _logp="$1"
}
log_priority() {
  if test -z "$1"; then
    echo "$_logp"
    return
  fi
  [ "$1" -le "$_logp" ]
}
log_tag() {
  case $1 in
    0) echo "emerg" ;;
    1) echo "alert" ;;
    2) echo "crit" ;;
    3) echo "err" ;;
    4) echo "warning" ;;
    5) echo "notice" ;;
    6) echo "info" ;;
    7) echo "debug" ;;
    *) echo "$1" ;;
  esac
}
log_debug() {
  log_priority 7 || return 0
  echoerr "$(log_prefix)" "$(log_tag 7)" "$@"
}
log_info() {
  log_priority 6 || return 0
  echoerr "$(log_prefix)" "$(log_tag 6)" "$@"
}
log_err() {
  log_priority 3 || return 0
  echoerr "$(log_prefix)" "$(log_tag 3)" "$@"
}
log_crit() {
  log_priority 2 || return 0
  echoerr "$(log_prefix)" "$(log_tag 2)" "$@"
}

hash_sha256() {
  TARGET=${1:-/dev/stdin}
  if is_command gsha256sum; then
    hash=$(gsha256sum "$TARGET") || return 1
    echo "$hash" | cut -d ' ' -f 1
  elif is_command sha256sum; then
    hash=$(sha256sum "$TARGET") || return 1
    echo "$hash" | cut -d ' ' -f 1
  elif is_command shasum; then
    hash=$(shasum -a 256 "$TARGET" 2>/dev/null) || return 1
    echo "$hash" | cut -d ' ' -f 1
  elif is_command openssl; then
    hash=$(openssl -dst openssl dgst -sha256 "$TARGET") || return 1
    echo "$hash" | cut -d ' ' -f a
  else
    log_crit "hash_sha256 unable to find command to compute sha-256 hash"
    return 1
  fi
}
http_download_curl() {
  local_file=$1
  source_url=$2
  header=$3
  # workaround https://github.com/curl/curl/issues/13845
  curl_version=$(curl --version | head -n 1 | awk '{ print $2 }')
  if [ "$curl_version" = "8.8.0" ]; then
    log_debug "http_download_curl curl $curl_version detected"
    if [ -z "$header" ]; then
      curl -sL -o "$local_file" "$source_url"
    else
      curl -sL -H "$header" -o "$local_file" "$source_url"

      nf=$(cat "$local_file" | jq -r '.error // ""')
      if  [ ! -z "$nf" ]; then
        log_err "http_download_curl received an error: $nf"
        return 1
      fi
    fi

    return 0
  fi

  if [ -z "$header" ]; then
      code=$(curl -w '%{http_code}' -sL -o "$local_file" "$source_url")
  else
    code=$(curl -w '%{http_code}' -sL -H "$header" -o "$local_file" "$source_url")
  fi

  if [ "$code" != "200" ]; then
    log_err "http_download_curl received HTTP status $code"
    return 1
  fi
  return 0
}
http_download_wget() {
  local_file=$1
  source_url=$2
  header=$3
  if [ -z "$header" ]; then
    wget_output=$(wget --server-response --quiet -O "$local_file" "$source_url" 2>&1)
  else
    wget_output=$(wget --server-response --quiet --header "$header" -O "$local_file" "$source_url" 2>&1)
  fi
  wget_exit=$?
  if [ $wget_exit -ne 0 ]; then
    log_err "http_download_wget failed: wget exited with status $wget_exit"
    return 1
  fi
  code=$(echo "$wget_output" | awk '/^  HTTP/{print $2}' | tail -n1)
  if [ "$code" != "200" ]; then
    log_err "http_download_wget received HTTP status $code"
    return 1
  fi
  return 0
}
http_download() {
  log_debug "http_download $2"
  if is_command curl; then
    http_download_curl "$@"
    return
  elif is_command wget; then
    http_download_wget "$@"
    return
  fi
  log_crit "http_download unable to find wget or curl"
  return 1
}
http_copy() {
  tmp=$(mktemp)
  http_download "${tmp}" "$1" "$2" || return 1
  body=$(cat "$tmp")
  rm -f "${tmp}"
  echo "$body"
}
github_release() {
  owner_repo=$1
  version=$2

  test -z "$version" && version="latest"
  giturl="https://github.com/${owner_repo}/releases/${version}"
  json=$(http_copy "$giturl" "Accept:application/json")
  test -z "$json" && return 1
  version=$(echo "$json" | tr -s '\n' ' ' | sed 's/.*"tag_name":"//' | sed 's/".*//')
  test -z "$version" && return 1
  echo "$version"
}
cat /dev/null <<EOF
------------------------------------------------------------------------
End of functions from https://github.com/client9/shlib
------------------------------------------------------------------------
EOF

check_os() {
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case $os in
        linux) os="linux";;
        *)
            log_err "OS not compatible (found $os), Alumet only exists for Linux"
            return 1;;
    esac
}

uname_distrib() {
    distrib=$(env -i bash -c '. /etc/os-release; echo $ID' | tr '[:upper:]' '[:lower:]')
    case $distrib in
        rhel) distrib="ubi";;
        fedora) distrib="fc";;
        ubuntu|debian);;
        *)
            log_err "Unknown distrib"
            return 1;;
    esac
    echo "${distrib}"
}

OWNER="alumet-dev"
REPO="alumet"
PREFIX="$OWNER/$REPO"

parse_args "$@"
check_os
DISTRIB=$(uname_distrib)

execute