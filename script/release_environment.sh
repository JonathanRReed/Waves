# Shared startup boundary for release-sensitive shell entry points.
#
# Callers must enter through /bin/bash -p and source this file by a canonical
# absolute path before running any external command. This function snapshots
# only the named, documented inputs, removes every inherited exported variable
# with shell builtins, validates the snapshots, and then installs the fixed
# release environment.

waves_release_environment_error() {
  printf 'Error: %s\n' "$1" >&2
  return 2
}

waves_release_environment_validate_input() {
  local name="$1"
  local value="$2"

  case "$name" in
    SIGN_IDENTITY)
      if [ -z "$value" ] || [ "${#value}" -gt 512 ] \
        || [[ "$value" == *$'\n'* ]] || [[ "$value" == *$'\r'* ]]; then
        waves_release_environment_error "SIGN_IDENTITY is not a valid single-line signing identity."
        return 2
      fi
      ;;
    NOTARY_PROFILE)
      if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
        waves_release_environment_error "NOTARY_PROFILE is not a valid keychain profile name."
        return 2
      fi
      ;;
    WAVES_EXPECTED_REVISION)
      if [[ ! "$value" =~ ^[0-9a-f]{40}$ ]]; then
        waves_release_environment_error "WAVES_EXPECTED_REVISION must be a lowercase 40-character Git revision."
        return 2
      fi
      ;;
    WAVES_RELEASE_EVIDENCE)
      if [ -z "$value" ] || [ "${#value}" -gt 4096 ] \
        || [[ "$value" == *$'\n'* ]] || [[ "$value" == *$'\r'* ]]; then
        waves_release_environment_error "WAVES_RELEASE_EVIDENCE is not a valid single-line path."
        return 2
      fi
      ;;
    WAVES_RELEASE_TAG)
      if [[ ! "$value" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        waves_release_environment_error "WAVES_RELEASE_TAG must match vX.Y.Z with canonical numeric components."
        return 2
      fi
      ;;
    EXPECTED_SHA256)
      if [[ ! "$value" =~ ^[0-9a-fA-F]{64}$ ]]; then
        waves_release_environment_error "EXPECTED_SHA256 must be a 64-character hexadecimal digest."
        return 2
      fi
      ;;
    SMOKE_SECONDS)
      if [[ ! "$value" =~ ^[1-9][0-9]*$ ]] || [ "$value" -gt 3600 ]; then
        waves_release_environment_error "SMOKE_SECONDS must be an integer from 1 through 3600."
        return 2
      fi
      ;;
    SMOKE_LOG_PATH)
      if [[ "$value" != /* ]] || [ "${#value}" -gt 4096 ] \
        || [[ "$value" == *$'\n'* ]] || [[ "$value" == *$'\r'* ]]; then
        waves_release_environment_error "SMOKE_LOG_PATH must be a valid absolute single-line path."
        return 2
      fi
      ;;
    *)
      waves_release_environment_error "release bootstrap input $name is not allowlisted."
      return 2
      ;;
  esac
}

waves_release_environment_cleanup() {
  local root="${WAVES_RELEASE_ENVIRONMENT_ROOT:-}"
  WAVES_RELEASE_ENVIRONMENT_ROOT=""

  case "$root" in
    /private/tmp/waves-release-environment.*)
      if [ -d "$root" ] && [ ! -L "$root" ]; then
        /bin/rm -rf -- "$root"
      fi
      ;;
  esac
}

waves_release_environment_bootstrap() {
  # Remove attacker-selected attributes from internal names before declaring
  # locals. Bash otherwise preserves an inherited export attribute on `local`.
  unset __waves_allowed_names __waves_allowed_values __waves_allowed_sets \
    __waves_exported_names __waves_index __waves_name __waves_value \
    __waves_owner __waves_mode __waves_root 2>/dev/null || :

  local -a __waves_allowed_names=()
  local -a __waves_allowed_values=()
  local -a __waves_allowed_sets=()
  local __waves_exported_names=""
  local __waves_index=0
  local __waves_name=""
  local __waves_value=""
  local __waves_owner=""
  local __waves_mode=""
  local __waves_root=""

  for __waves_name in "$@"; do
    case "$__waves_name" in
      SIGN_IDENTITY|NOTARY_PROFILE|WAVES_EXPECTED_REVISION|WAVES_RELEASE_EVIDENCE|WAVES_RELEASE_TAG|EXPECTED_SHA256|SMOKE_SECONDS|SMOKE_LOG_PATH) ;;
      *)
        waves_release_environment_error "release bootstrap input $__waves_name is not allowlisted."
        return 2
        ;;
    esac
    __waves_allowed_names[$__waves_index]="$__waves_name"
    if [ "${!__waves_name+x}" = x ]; then
      __waves_allowed_sets[$__waves_index]=1
      __waves_allowed_values[$__waves_index]="${!__waves_name}"
    else
      __waves_allowed_sets[$__waves_index]=0
      __waves_allowed_values[$__waves_index]=""
    fi
    __waves_index=$((__waves_index + 1))
  done

  # `compgen`, `export -n`, and `unset` are Bash builtins. No external
  # executable or new interpreter image starts with inherited exported state.
  IFS=$' \t\n'
  __waves_exported_names="$(compgen -e)"
  for __waves_name in $__waves_exported_names; do
    export -n "$__waves_name" 2>/dev/null || :
    unset "$__waves_name" 2>/dev/null || :
  done
  IFS=$' \t\n'

  PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  LC_ALL="C.UTF-8"
  LANG="C.UTF-8"
  GIT_CONFIG_GLOBAL="/dev/null"
  GIT_CONFIG_NOSYSTEM="1"
  GIT_TERMINAL_PROMPT="0"
  GCM_INTERACTIVE="never"
  GIT_ASKPASS="/usr/bin/false"
  SSH_ASKPASS="/usr/bin/false"
  GIT_SSH_COMMAND="/usr/bin/ssh -F /dev/null -oBatchMode=yes"
  export PATH LC_ALL LANG GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM \
    GIT_TERMINAL_PROMPT GCM_INTERACTIVE GIT_ASKPASS SSH_ASKPASS GIT_SSH_COMMAND

  __waves_root="$(/usr/bin/mktemp -d /private/tmp/waves-release-environment.XXXXXX)" || {
    waves_release_environment_error "could not create the private release environment."
    return 1
  }
  /bin/chmod 700 "$__waves_root"
  /bin/mkdir "$__waves_root/home" "$__waves_root/tmp"
  /bin/chmod 700 "$__waves_root/home" "$__waves_root/tmp"
  __waves_owner="$(/usr/bin/stat -f '%u' "$__waves_root")"
  __waves_mode="$(/usr/bin/stat -f '%Lp' "$__waves_root")"
  if [ "$__waves_owner" != "$EUID" ] || [ "$__waves_mode" != "700" ] \
    || [ -L "$__waves_root" ] || [ ! -d "$__waves_root/home" ] \
    || [ -L "$__waves_root/home" ] || [ ! -d "$__waves_root/tmp" ] \
    || [ -L "$__waves_root/tmp" ]; then
    /bin/rm -rf -- "$__waves_root"
    waves_release_environment_error "private HOME and TMPDIR validation failed."
    return 1
  fi

  WAVES_RELEASE_ENVIRONMENT_ROOT="$__waves_root"
  HOME="$__waves_root/home"
  TMPDIR="$__waves_root/tmp"
  CFFIXED_USER_HOME="$HOME"
  XDG_CACHE_HOME="$HOME/.cache"
  XDG_CONFIG_HOME="$HOME/.config"
  export HOME TMPDIR CFFIXED_USER_HOME XDG_CACHE_HOME XDG_CONFIG_HOME
  umask 077
  trap waves_release_environment_cleanup EXIT INT TERM HUP

  __waves_index=0
  while [ "$__waves_index" -lt "${#__waves_allowed_names[@]}" ]; do
    if [ "${__waves_allowed_sets[$__waves_index]}" -eq 1 ]; then
      __waves_name="${__waves_allowed_names[$__waves_index]}"
      __waves_value="${__waves_allowed_values[$__waves_index]}"
      if ! waves_release_environment_validate_input "$__waves_name" "$__waves_value"; then
        waves_release_environment_cleanup
        return 2
      fi
      printf -v "$__waves_name" '%s' "$__waves_value"
      export "$__waves_name"
    fi
    __waves_index=$((__waves_index + 1))
  done
}
