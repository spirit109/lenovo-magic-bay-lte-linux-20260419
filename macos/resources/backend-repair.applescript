on run
    set choice to button returned of (display dialog "此工具只更新 Magic Bay LTE 2 的联网组件，保留当前 Wi-Fi。\n\n安装后仍需测试长期稳定性；如遇问题，可再次打开此工具恢复本轮修复前的组件。" buttons {"取消", "恢复原组件", "安装修复"} default button "安装修复" cancel button "取消" with title "Magic Bay 联网修复")
    if choice is "恢复原组件" then
        set repairAction to "restore"
    else
        set repairAction to "install"
    end if
    set scriptPath to POSIX path of (path to resource "repair-lock")
    try
        do shell script quoted form of scriptPath & " " & repairAction with administrator privileges
        if repairAction is "restore" then
            display dialog "已恢复本轮修复前的联网组件。当前 Wi-Fi 保持不变。" buttons {"好"} default button "好" with title "Magic Bay 联网修复"
        else
            display dialog "修正后的联网组件已安装。请继续通过 Magic Bay LTE 2 连接，观察是否仍会掉线。\n\n需要回退时，再打开本工具并选择“恢复原组件”。" buttons {"好"} default button "好" with title "Magic Bay 联网修复"
        end if
    on error messageText number errorNumber
        if errorNumber is not -128 then
            display dialog messageText buttons {"好"} default button "好" with title "Magic Bay 联网修复"
        end if
    end try
end run
