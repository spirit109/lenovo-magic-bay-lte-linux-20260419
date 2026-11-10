on run
    set choice to button returned of (display dialog "诊断版会在同一 USB 句柄内记录实时信号和收发统计。\n\n切换会短暂断开 LTE；若 120 秒内未通过信号与直连检查，将启动恢复稳定版。此工具也提供手动恢复入口。\n\n如果当前没有可用的备用网络，建议先准备好其他 Wi-Fi 或手机热点。" buttons {"取消", "恢复稳定版", "试用诊断版"} default button "试用诊断版" cancel button "取消" with title "Magic Bay 诊断与回退")
    if choice is "恢复稳定版" then
        set actionName to "restore"
    else
        set actionName to "trial"
    end if
    set scriptPath to POSIX path of (path to resource "diagnostic-trial.py")
    try
        set receipt to do shell script "/usr/bin/python3 -I " & quoted form of scriptPath & " " & actionName with administrator privileges
        if actionName is "restore" then
            display dialog "稳定版组件已恢复。请在 Magic Bay LTE 2 中确认连接状态；若当前未连接，点击“连接 LTE”。" buttons {"好"} default button "好" with title "Magic Bay 诊断与回退"
        else
            display dialog "诊断版已启动，实时信号与联网检查已通过。监测会继续留存故障前后记录。\n\n需要回退时，再打开本工具选择“恢复稳定版”。" buttons {"好"} default button "好" with title "Magic Bay 诊断与回退"
        end if
    on error messageText number errorNumber
        if errorNumber is not -128 then
            display dialog "操作未确认完成。请保留本工具，必要时选择“恢复稳定版”，或使用桌面“恢复家庭网络”。\n\n" & messageText buttons {"好"} default button "好" with title "Magic Bay 诊断与回退"
        end if
    end try
end run
