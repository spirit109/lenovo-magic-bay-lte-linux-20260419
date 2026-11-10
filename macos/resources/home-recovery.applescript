on run
    set choice to button returned of (display dialog "这会停止 Magic Bay LTE，并重新开启家庭 Wi-Fi。\n\n如果系统未自动连接，请在 Wi-Fi 菜单选择家里已保存的网络，无需输入代码。" buttons {"取消", "恢复家庭网络"} default button "恢复家庭网络" cancel button "取消" with title "恢复家庭网络")
    set recoveryTool to POSIX path of (path to resource "recovery-rootctl")
    try
        do shell script quoted form of recoveryTool & " recover-home" with administrator privileges
        display dialog "家庭网络已恢复。" buttons {"好"} default button "好" with title "恢复家庭网络"
    on error messageText number errorNumber
        if errorNumber is not -128 then
            display dialog messageText buttons {"好"} default button "好" with title "恢复家庭网络"
        end if
    end try
end run
