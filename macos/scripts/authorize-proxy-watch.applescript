on run argv
    if (count of argv) is not 1 then error "需要已编译的代理兼容工具路径。"
    set toolPath to quoted form of (item 1 of argv)
    set commandText to "set -e" & linefeed & toolPath & " self-test" & linefeed & toolPath & " start" & linefeed & toolPath & " status" & linefeed & toolPath & " stop" & linefeed & toolPath & " start"
    with timeout of 240 seconds
        return do shell script commandText with administrator privileges
    end timeout
end run
