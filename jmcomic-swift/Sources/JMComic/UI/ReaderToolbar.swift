import SwiftUI
import CoreGraphics

extension ReaderCore {

    // MARK: - 顶栏

    var toolbar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Label("关闭", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(title)

            headerExtra()

            if pageCount > 0 {
                Text("\(min(session.visiblePage + 1, pageCount)) / \(pageCount)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Menu {
                Picker("阅读方式", selection: $readerMode) {
                    ForEach(ReaderMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                if readerMode != .continuous {
                    Divider()
                    Picker("翻页方式", selection: $paging) {
                        ForEach(PagingStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                }
                if readerMode == .spread {
                    Divider()
                    Picker("双页方向", selection: $spreadDirection) {
                        ForEach(SpreadDirection.allCases) { dir in
                            Text(dir.shortLabel).tag(dir)
                        }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label(readerMode.label, systemImage: readerMode.icon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .help("阅读方式：单页 / 连续 / 双页（双页时第 1 页单独，之后两两对开）")

            Button {
                showDisplayOptions.toggle()
            } label: {
                Label("画面", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("画面：适配方式 / 大小 / 间距 / 裁黑（按作品记住）")
            .popover(isPresented: $showDisplayOptions, arrowEdge: .top) {
                displayOptions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    // MARK: - 底部跳页条

    var jumpBar: some View {
        // Slider 的 range 不能是 1...1（Normalizing 断言会崩），只有一页时不渲染
        Group {
            if pageCount > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "book")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $sliderPage, in: 1...Double(pageCount), step: 1) { editing in
                        if editing {
                            // 拖动期间保持顶栏可见：先唤出、再暂停自动收起计时
                            showChromeTemporarily()
                            chromeHideTask?.cancel()
                        } else {
                            jumpTarget = min(max(Int(sliderPage) - 1, 0), pageCount - 1)
                            showChromeTemporarily()
                        }
                    }
                    .frame(maxWidth: 300)
                    // 只镜像滑块：右→左阅读时拖动方向与翻页方向一致（文字不翻）
                    .scaleEffect(x: spreadDirection == .rightToLeft ? -1 : 1)
                    Text("\(Int(sliderPage)) / \(pageCount)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - 顶栏行为

    /// 点击切换控制栏：出现时再点一次就收起
    func toggleChrome() {
        if chromeVisible { hideChrome() } else { showChromeTemporarily() }
    }

    /// 显示控制栏，3 秒后自动收起
    func showChromeTemporarily() {
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = true }
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 弹窗开着或计时被取消：不收（弹窗关闭时会重新计时）
            guard !Task.isCancelled, !showDisplayOptions else { return }
            hideChrome()
        }
    }

    /// 收起控制栏（并取消自动收起计时）
    func hideChrome() {
        chromeHideTask?.cancel()
        chromeHideTask = nil
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
    }

    /// 顶栏「画面」弹窗：适配方式 / 大小 / 间距 / 裁黑（都按作品记）
    var displayOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("画面适配", selection: $fitMode) {
                ForEach(FitMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("适应窗口=整屏恰好嵌进窗口（打开即契合）；适应宽度=铺满宽度往下滚；手动=自己拖大小。")
                .font(.caption2).foregroundStyle(.secondary)

            if fitMode == .manual {
                HStack(spacing: 8) {
                    Text("大小").font(.caption).frame(width: 32, alignment: .leading)
                    Slider(value: $pageSize, in: 0.5...1.5, step: 0.05) { editing in
                        if !editing { ReaderPrefs.setSize(pageSize, albumId: albumId) }
                    }
                    .frame(width: 180)
                    Text("\(Int(pageSize * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            HStack(spacing: 8) {
                Text("间距").font(.caption).frame(width: 32, alignment: .leading)
                Slider(value: $pageGap, in: 0...60, step: 1) { editing in
                    if !editing { ReaderPrefs.setGap(pageGap, albumId: albumId) }
                }
                .frame(width: 180)
                Text("\(Int(pageGap))pt")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Toggle(isOn: $trimBlack) {
                Text("裁掉贴边黑带").font(.caption)
            }
            Text("只裁整条贯穿的纯黑边带（扫描件黑边），画面里的黑不碰；默认关。")
                .font(.caption2).foregroundStyle(.secondary)

            Text("都按作品记住。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - 键盘

    func installKeyboard() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { ev in
            // 鼠标移动不唤出控制栏：按需求"不点击就不出现"
            if ev.type == .mouseMoved { return ev }
            switch ev.keyCode {
            case 123:            // ← 上一页
                self.pageStep(-1)
                return nil
            case 124, 49:        // → / 空格 下一页
                self.pageStep(1)
                return nil
            default:
                return ev
            }
        }
    }

    func pageStep(_ delta: Int) {
        let total = max(pageCount, 1)
        let target = max(0, min(session.visiblePage + delta, total - 1))
        guard target != session.visiblePage else { return }
        jumpTarget = target
        hideChrome()
    }

    func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
