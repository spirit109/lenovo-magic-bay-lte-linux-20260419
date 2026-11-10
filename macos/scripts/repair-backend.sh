#!/bin/sh
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || {
    echo '此修复组件仅适用于 Apple Silicon macOS。' >&2; exit 69;
}
[ "$#" = 1 ] || exit 64
action=$1
case "$action" in install|restore|--check|--self-test) ;; *) exit 64 ;; esac
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
case "$script_dir" in */Contents/Resources) ;; *) echo '请从本项目生成的修复应用运行。' >&2; exit 64 ;; esac
project_dir=$(CDPATH= cd -- "$script_dir/../../../../.." && pwd -P)
test -f "$project_dir/AGENTS.md"
test -f "$project_dir/backend/mbim_net.c"
candidate="$script_dir/mbim-net-candidate"
original="$script_dir/original-backend"
target=/usr/local/libexec/magic-bay-lte-v2/mbim-net
original_hash=efd1f7316c0cfac40cba60711bc5b67dd19a8dcdd2d81bd2d244cd1a6067418c
candidate_hash=0992777db5621628871e826a27981c8f96ead02f964c1d6ec1e6e3b5d344b295
file_hash() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
default_identity() { /sbin/route -n get default | /usr/bin/awk '/gateway:|interface:/ {print $2}'; }
replace_component() (
    target=$1
    backup=$2
    source=$3
    expected=$4
    fail_after_move=$5
    require_root=$6
    before=$7
    stage="$backup/replacement"
    if [ "$require_root" = 1 ]; then
        /usr/bin/install -o root -g wheel -m 755 "$source" "$stage"
    else
        /usr/bin/install -m 755 "$source" "$stage"
    fi
    [ "$(file_hash "$stage")" = "$expected" ]
    /usr/bin/codesign --verify --strict "$stage"
    success=0
    moved=0
    rollback() {
        [ "$success" = 0 ] && [ "$moved" = 1 ] || return 0
        if [ -e "$target" ]; then /bin/mv "$target" "$backup/failed-replacement"; fi
        /bin/mv "$backup/installed-backend" "$target"
        echo "更新未完成，已恢复原组件；文件保留在 $backup" >&2
    }
    trap rollback EXIT
    trap 'exit 1' HUP INT TERM
    /bin/mv "$target" "$backup/installed-backend"
    moved=1
    /bin/mv "$stage" "$target"
    [ "$fail_after_move" = 0 ] || exit 86
    [ "$(file_hash "$target")" = "$expected" ]
    if [ "$require_root" = 1 ]; then [ "$(stat -f '%u' "$target")" = 0 ]; fi
    [ "$(stat -f '%Lp' "$target")" = 755 ]
    /usr/bin/codesign --verify --strict "$target"
    [ "$(default_identity)" = "$before" ]
    success=1
)
for file in "$candidate" "$original" "$target"; do
    [ -f "$file" ] && [ ! -L "$file" ] || { echo '组件文件缺失或不是普通文件。' >&2; exit 78; }
    /usr/bin/codesign --verify --strict "$file"
done
[ "$(file_hash "$candidate")" = "$candidate_hash" ]
[ "$(file_hash "$original")" = "$original_hash" ]
current_hash=$(file_hash "$target")
case "$current_hash" in "$original_hash"|"$candidate_hash") ;; *)
    echo '联网组件已被其他版本更新，本工具不会覆盖它。' >&2; exit 78 ;;
esac
if [ "$action" = --check ]; then
    echo "candidate_verified=1 original_verified=1 installed_hash=$current_hash"
    echo 'network_started=0 files_changed=0'
    exit 0
fi
if [ "$action" = --self-test ]; then
    # This branch has only locally generated fixture paths. It does not use
    # the privileged target as a transaction destination, even when run as root.
    test_dir="$project_dir/_RecycleBin/repair-selftest-$(date '+%Y%m%d-%H%M%S')-$$"
    /bin/mkdir -p "$test_dir/install" "$test_dir/restore" "$test_dir/failure"
    fixture="$test_dir/fixture-backend"
    /usr/bin/install -m 755 "$original" "$fixture"
    baseline=$(default_identity)
    replace_component "$fixture" "$test_dir/install" "$candidate" "$candidate_hash" 0 0 "$baseline"
    [ "$(file_hash "$fixture")" = "$candidate_hash" ]
    replace_component "$fixture" "$test_dir/restore" "$original" "$original_hash" 0 0 "$baseline"
    [ "$(file_hash "$fixture")" = "$original_hash" ]
    set +e
    (set -e; replace_component "$fixture" "$test_dir/failure" "$candidate" "$candidate_hash" 1 0 "$baseline")
    failed=$?
    set -e
    [ "$failed" = 86 ]
    [ "$(file_hash "$fixture")" = "$original_hash" ]
    [ "$(file_hash "$target")" = "$current_hash" ]
    echo "fixture_install=passed fixture_restore=passed forced_failure_rollback=passed evidence=$test_dir"
    echo 'installed_component_changed=0 network_started=0'
    exit 0
fi
[ "$(id -u)" = 0 ] || { echo 'administrator_required' >&2; exit 77; }
for directory in /usr/local /usr/local/libexec /usr/local/libexec/magic-bay-lte-v2; do
    [ -d "$directory" ] && [ ! -L "$directory" ] && [ "$(stat -f '%u' "$directory")" = 0 ] || exit 78
    mode=$(stat -f '%Lp' "$directory")
    [ "$((0$mode & 0022))" = 0 ] || exit 78
done
[ "$(stat -f '%u' "$target")" = 0 ] || exit 78
mode=$(stat -f '%Lp' "$target")
[ "$((0$mode & 0022))" = 0 ] || exit 78
if /bin/ps -axo comm= | /usr/bin/awk '/\/(mbim-net|mbim-net-candidate|ncm-packet-trial)$/ { found=1 } END { exit !found }'; then
    echo 'Magic Bay 联网或诊断后台仍在运行，请先结束诊断或在客户端断开 LTE。' >&2
    exit 75
fi
before=$(default_identity)
[ -n "$before" ] || { echo '没有可验证的备用网络，未更新组件。' >&2; exit 75; }
if printf '%s\n' "$before" | /usr/bin/grep -Eq '^utun'; then
    echo '请先使用稳定的 Wi-Fi 或有线网络，再安装或恢复组件。' >&2; exit 75
fi
if [ "$action" = install ]; then source=$candidate; expected=$candidate_hash
else source=$original; expected=$original_hash; fi
if [ "$current_hash" = "$expected" ]; then echo 'requested_version_already_installed=1'; exit 0; fi
recycle="$project_dir/_RecycleBin"
[ ! -L "$recycle" ] || exit 78
/bin/mkdir -p "$recycle"
[ "$(stat -f '%d' "$recycle")" = "$(stat -f '%d' "$target")" ] || {
    echo '回收区与组件不在同一文件系统，本工具不会进行非原子替换。' >&2; exit 78;
}
backup="$recycle/backend-transport-$(date '+%Y%m%d-%H%M%S')-$$"
/bin/mkdir -m 755 "$backup"
replace_component "$target" "$backup" "$source" "$expected" 0 1 "$before"
echo "action=$action component_verified=1 network_started=0 backup=$backup"
echo '没有修改 Wi-Fi、路由、DNS、代理、VPN、登录项或授权规则。'
