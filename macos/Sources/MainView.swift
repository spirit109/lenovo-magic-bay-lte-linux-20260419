import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppController
    private var healthy: Bool { model.phase == .online }
    private var accent: Color { healthy ? .green : (model.phase == .limited || model.phase == .conflict ? .orange : .blue) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 25, weight: .medium)).foregroundStyle(.blue)
                        .frame(width: 52, height: 52).background(.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Magic Bay LTE").font(.system(size: 20, weight: .semibold))
                        Text("随时连接，自在上网").foregroundStyle(.secondary).font(.system(size: 13))
                    }
                    Spacer()
                    Text("v" + AppRelease.version).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }

                if model.readOnly {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("只读观察 · 当前连接受到保护").fontWeight(.semibold)
                            Text(model.readOnlyExplanation)
                                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } icon: { Image(systemName: "eye").font(.system(size: 20)).foregroundStyle(.blue) }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: healthy ? "checkmark.circle.fill" : "circle.dotted").foregroundStyle(accent)
                        Text(model.snapshot.provider ?? (model.snapshot.running ? "蜂窝网络" : "移动网络"))
                        if model.snapshot.running { Text("·"); Text("LTE") }
                        Spacer()
                        ZStack {
                            if model.busy || model.showsProbeProgress { ProgressView().controlSize(.small).accessibilityLabel("正在检测连接") }
                        }.frame(width: 18, height: 18)
                    }.font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)

                    Text(model.phase.title).font(.system(size: 30, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(model.subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    HStack(spacing: 12) {
                        Button(action: model.primaryAction) {
                            Label(model.primaryTitle, systemImage: primarySymbol)
                                .font(.system(size: 14, weight: .semibold)).frame(minWidth: 155, minHeight: 28)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!model.primaryEnabled)
                            .accessibilityHint(model.canHandoff ? "正常退出旧版界面并显示新版连接控制，现有联网后台会保留" : "")
                        Button {
                            if model.phase == .limited { model.expanded = true } else { model.refresh(forceProbe: true, userInitiated: true) }
                        } label: {
                            Label(model.phase == .limited ? "查看诊断" : (model.userRefreshing ? "正在检测…" : "重新检测"), systemImage: model.phase == .limited ? "list.bullet.clipboard" : "arrow.clockwise")
                        }.buttonStyle(.bordered).controlSize(.large)
                            .keyboardShortcut("r", modifiers: .command)
                            .disabled(model.busy || (model.phase != .limited && !model.refreshEnabled))
                        if model.showsSeparateDisconnect {
                            Button(action: model.confirmDisconnect) {
                                Label("断开 LTE", systemImage: "power")
                            }.buttonStyle(.bordered).controlSize(.large)
                                .disabled(!model.disconnectEnabled)
                        }
                        Spacer()
                    }.padding(.top, 4)
                    if model.busy {
                        Text(model.handingOver ? "正在等待旧版界面退出，LTE 后台仍保留。" : (model.operation == .authorize ? "请在 macOS 系统窗口中完成或取消授权。" : "正在处理本次操作，完成前不会发起第二次请求。"))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.07)))

                if !model.notice.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: model.noticeIsError ? "exclamationmark.circle" : "info.circle")
                            .foregroundStyle(model.noticeIsError ? .orange : .blue)
                        Text(model.notice).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button { model.notice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("关闭提示")
                    }.padding(14).background((model.noticeIsError ? Color.orange : Color.blue).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("连接检查").font(.system(size: 15, weight: .semibold))
                        Spacer()
                        Text(checkTime).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 18) {
                        checkTile("联网后台", symbol: "antenna.radiowaves.left.and.right", value: model.snapshot.backendInterrupted ? "正在释放旧连接" : (model.snapshot.running ? "正在运行" : "尚未运行"),
                                  detail: model.snapshot.backendInterrupted ? "失效连接会自动清理" : (model.snapshot.running ? "独立后台 · 退出窗口仍保持连接" : "连接时自动建立蜂窝会话"), status: model.snapshot.running && !model.snapshot.backendInterrupted ? .passed : .unknown)
                        checkTile("系统默认路径", symbol: "point.3.connected.trianglepath.dotted", value: model.snapshot.routeMatches ? (model.snapshot.backendInterrupted ? "旧 LTE 路径待释放" : "使用 LTE") : (model.snapshot.defaultInterface == nil ? "尚无默认路径" : "使用其他网络"),
                                  detail: model.snapshot.routeMatches ? (model.snapshot.interface ?? "") : "LTE 不会自动抢回默认路由", status: model.snapshot.routeMatches && !model.snapshot.backendInterrupted ? .passed : .unknown)
                        checkTile("LTE 直连", symbol: "globe", value: directTitle,
                                  detail: directDetail, status: model.freshEvidence.map { $0.directPassed ? .passed : .failed } ?? .unknown)
                        checkTile("系统访问", symbol: "network", value: systemTitle,
                                  detail: model.snapshot.proxySummary + (model.snapshot.otherTunnelRoutes ? " · 存在其他隧道路由" : ""), status: model.freshEvidence?.system.outcome ?? .unknown)
                    }
                }

                if let traffic = model.traffic {
                    HStack(spacing: 24) {
                        trafficItem("下载", value: byteText(traffic.rxPerSecond) + "/s", symbol: "arrow.down")
                        trafficItem("上传", value: byteText(traffic.txPerSecond) + "/s", symbol: "arrow.up")
                        Spacer()
                        trafficItem("本次连接流量", value: byteText(Double(traffic.total)), symbol: "chart.bar")
                    }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }

                DisclosureGroup(isExpanded: $model.expanded) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .center, spacing: 12) {
                            Text("运营商 APN").frame(width: 94, alignment: .leading)
                            TextField("例如 3gnet", text: $model.apn).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                                .disabled(model.busy || model.snapshot.running || model.readOnly).accessibilityLabel("运营商 APN")
                            Spacer()
                        }
                        Text("中国联通常用 3gnet，移动常用 cmnet，电信常用 ctnet；请以当前套餐要求为准。修改后下次连接生效。")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("联网权限 · " + authorizationTitle).fontWeight(.medium)
                                Text("仅首次设置需要 macOS 管理员授权。").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("设置权限", action: model.authorize).disabled(model.readOnly || model.busy || (model.snapshot.running && model.snapshot.runtime?.directory == RuntimePaths.current.directory))
                        }
                        if model.snapshot.running {
                            HStack(spacing: 12) {
                                Button("修复路由与 DNS", action: model.confirmRepair).disabled(model.readOnly || model.busy || !model.snapshot.interfacePresent)
                                Button("断开 LTE…", action: model.confirmDisconnect).disabled(!model.disconnectEnabled)
                            }
                        }
                        Divider()
                        if let evidence = model.freshEvidence {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("最近一次检测").fontWeight(.medium)
                                ForEach(Array((evidence.direct + [evidence.system]).enumerated()), id: \.offset) { _, check in
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: check.outcome == .passed ? "checkmark.circle" : "exclamationmark.circle")
                                            .foregroundStyle(check.outcome == .passed ? Color.green : Color.orange)
                                        Text(check.name).frame(width: 64, alignment: .leading)
                                        Text(check.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }.font(.system(size: 12))
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            detailLine("LTE 接口", model.snapshot.interface ?? "未建立")
                            detailLine("IPv4", model.snapshot.address ?? "未获取")
                            detailLine("设备提供的 DNS", model.snapshot.dns.isEmpty ? "未获取" : model.snapshot.dns.joined(separator: "、"))
                            detailLine("信号（连接时）", model.snapshot.rssi.map { $0 == 99 ? "未知" : "RSSI \($0) · 不是实时读数" } ?? "未获取")
                            detailLine("实时无线质量", model.snapshot.liveSignalQuality?.summary ?? "未取得新鲜数据")
                            detailLine("硬件型号", model.snapshot.hardwareModel ?? "连接后读取")
                            detailLine("固件版本", model.snapshot.firmwareVersion ?? "连接后读取")
                        }.font(.system(size: 12))
                        HStack {
                            Button("复制诊断摘要", action: model.copyDiagnostics)
                            Spacer()
                            Text("检测每 60 秒更新；流量统计仅供参考。").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.padding(.top, 16)
                } label: { Text("设置与诊断").font(.system(size: 14, weight: .medium)) }
                .padding(18).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))

                Text(model.snapshot.backendInterrupted ? "旧连接会自动清理，重新插入后无需退出应用。" : "关闭窗口或退出应用，会保留可用的 LTE 连接。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(28).frame(maxWidth: 900).frame(maxWidth: .infinity)
        }.background(Color(nsColor: .windowBackgroundColor)).frame(minWidth: 640, minHeight: 620)
    }

    private var primarySymbol: String {
        if model.canHandoff { return "arrow.right.circle" }
        if model.readOnly { return "eye" }
        if model.snapshot.authorization != .ready { return "lock.shield" }
        if model.phase == .limited { return "arrow.clockwise" }
        if model.phase == .routeMismatch { return "arrow.triangle.branch" }
        return "power"
    }
    private var checkTime: String { model.showsProbeProgress ? "检测中" : model.freshEvidence.map { "检测于 " + $0.checkedAt.formatted(date: .omitted, time: .standard) } ?? "等待本次连接检测" }
    private var directTitle: String { model.freshEvidence.map { $0.directPassed ? "可以访问互联网" : "暂未通过" } ?? "尚未验证" }
    private var directDetail: String {
        guard let evidence = model.freshEvidence else { return "在 LTE 接口上验证 HTTPS 访问" }
        return "\(evidence.direct.filter { $0.outcome == .passed }.count)/\(evidence.direct.count) 个检测站点通过 · \(model.snapshot.interface ?? "LTE")"
    }
    private var systemTitle: String {
        switch model.freshEvidence?.system.outcome {
        case .passed: return "访问正常"
        case .failed: return "系统检测未通过"
        default: return "尚未验证"
        }
    }
    private var authorizationTitle: String {
        switch model.snapshot.authorization {
        case .ready: return "已就绪"
        case .outdated: return "需要更新联网组件"
        case .missing: return "尚未设置新版权限"
        case .denied: return "需要授权"
        case .unknown: return "正在确认"
        }
    }
    private func checkTile(_ title: String, symbol: String, value: String, detail: String, status: ProbeOutcome) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
                Label(value, systemImage: status == .passed ? "checkmark.circle.fill" : (status == .failed ? "exclamationmark.circle" : "minus.circle"))
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(status == .failed ? Color.orange : Color.primary)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func trafficItem(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium, design: .monospaced)).monospacedDigit()
        }.frame(width: 128, alignment: .leading)
    }
    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading); Text(value).textSelection(.enabled); Spacer() }
    }
}
