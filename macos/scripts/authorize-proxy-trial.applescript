on run argv
    if (count of argv) is not 1 then error "需要已编译的代理兼容工具路径。"
    set toolPath to item 1 of argv
    set commandText to "set -e" & linefeed & (quoted form of toolPath) & " self-test" & linefeed & (quoted form of toolPath) & " trial 120"
    with timeout of 240 seconds
        return do shell script commandText with administrator privileges
    end timeout
end run
