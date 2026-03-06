# ===================== 主程序入口 (纯交互模式) =====================
main() {
    # 1. 基础环境检查
    check_root
    check_lock
    detect_os
    backup_config
    
    log "INFO" "脚本已启动，进入交互模式"
    
    # 2. 欢迎提示 (防止用户直接在 shell 输入数字)
    echo -e "${BLUE}=============================================================${NC}"
    echo -e "${GREEN}✅ 脚本加载成功！请在下方菜单中输入数字进行操作。${NC}"
    echo -e "${YELLOW}⚠️  注意：请勿在脚本未运行时直接输入数字！${NC}"
    echo -e "${BLUE}=============================================================${NC}"
    echo ""

    # 3. 主循环
    while true; do
        show_main_menu
        
        # 读取用户输入
        read -p "请选择操作 (0-15)：" OPT_CHOICE
        
        case $OPT_CHOICE in
            1) module_sys_update ;;
            2) module_kernel_upgrade ;;
            3) module_ssh_custom ;;
            4) module_basic_optimize ;;
            5) module_kernel_bbr ;;
            6) module_swap_config ;;
            7) module_firewall_config ;;
            8) module_boot_service ;;
            9) module_app_optimize ;;
            10) module_security_harden ;;
            11) module_sys_clean ;;
            12) module_monitor_install ;;
            13) module_rollback ;;
            14) module_dns_config ;;
            15)
                log "INFO" "=== 开始执行全量优化 ==="
                # 全量执行列表
                module_sys_update
                module_kernel_upgrade
                module_ssh_custom
                module_basic_optimize
                module_kernel_bbr
                module_swap_config
                module_firewall_config
                module_boot_service
                module_app_optimize
                module_security_harden
                module_sys_clean
                module_monitor_install
                module_dns_config
                
                echo -e "\n${GREEN}🎉 全量优化完成！${NC}"
                echo -e "${YELLOW}📌 后续操作建议：${NC}"
                echo -e "   1. 若修改了 SSH 端口，请在新窗口测试连接后再关闭当前会话"
                echo -e "   2. 若升级了内核，请执行 'reboot' 重启服务器"
                echo -e "   3. 查看日志：cat $LOG_FILE"
                echo -e "   4. 备份目录：$BACKUP_DIR"
                log "INFO" "全量优化流程结束"
                ;;
            0)
                echo -e "${YELLOW}👋 退出脚本。日志已保存至：$LOG_FILE${NC}"
                log "INFO" "用户主动退出脚本"
                exit 0
                ;;
            *)
                echo -e "${RED}❌ 无效输入：'$OPT_CHOICE'，请输入 0-15 之间的数字！${NC}"
                sleep 1.5
                ;;
        esac
        
        # 如果不是退出或全量优化（全量优化后通常也退出或返回），暂停一下让用户看清提示
        if [ "$OPT_CHOICE" != "0" ]; then
            echo ""
            read -p "${CYAN}按回车键返回主菜单...${NC}"
        fi
    done
}

# 启动主程序 (不传递任何参数，强制交互)
main
