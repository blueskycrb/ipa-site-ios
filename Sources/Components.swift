import SwiftUI

struct AppIconView: View {
    let url: String?
    var size: CGFloat = 48

    var body: some View {
        AsyncImage(url: url.flatMap { URL(string: $0) }) { image in
            image.resizable()
        } placeholder: {
            Color.secondary.opacity(0.15)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// 安装按钮。按「设置」里的安装方式：
/// - TrollStore：打开 apple-magnifier://install?url=…，TrollStore 自己下载并安装，任何 IPA 都行
/// - 系统安装：打开 itms-services:// 链接，只对本站从 App Store 下载的 IPA 有效（systemAvailable）
struct InstallButton: View {
    let name: String
    let systemAvailable: Bool
    @Binding var toast: String?
    @AppStorage(Keys.installMode) private var mode = "system"
    @Environment(\.openURL) private var openURL
    @State private var working = false

    private var useTrollStore: Bool {
        mode == "trollstore" && [".ipa", ".tipa"].contains { name.lowercased().hasSuffix($0) }
    }

    var body: some View {
        if useTrollStore || systemAvailable {
            Button(working ? "准备中…" : (useTrollStore ? "TrollStore 安装" : "安装")) {
                Task { await install() }
            }
            .buttonStyle(.bordered)
            .disabled(working)
        }
    }

    private func install() async {
        working = true
        do {
            let (url, source) = try await API.installURL(name, mode: useTrollStore ? "trollstore" : "system")
            let from = source == "alist" ? "从 Alist 网盘" : "从服务器"
            toast = useTrollStore ? "\(from)交给 TrollStore 下载安装" : "\(from)安装：在弹窗里点「安装」，再回到主屏幕看进度"
            openURL(url) { accepted in
                if !accepted {
                    toast = useTrollStore ? "打不开 TrollStore：请确认已安装 TrollStore（2.0 以上）" : "系统没有接受安装链接"
                }
            }
        } catch {
            toast = error.localizedDescription
        }
        working = false
    }
}

/// 「存到手机」：可以选从服务器下载，或从 Alist 网盘直链下载（不占家里上行带宽）
struct SaveToPhoneButton: View {
    let name: String
    let alistAvailable: Bool
    @ObservedObject var phone: PhoneDownloads
    @Binding var toast: String?

    var body: some View {
        if alistAvailable {
            Menu {
                Button("从 Alist 下载（不限速）") { fromAlist() }
                Button("从服务器下载") { phone.start(name) }
            } label: {
                Text("存到手机")
            }
            .buttonStyle(.borderedProminent)
            .disabled(phone.isRunning(name))
        } else {
            Button("存到手机") { phone.start(name) }
                .buttonStyle(.borderedProminent)
                .disabled(phone.isRunning(name))
        }
    }

    private func fromAlist() {
        Task {
            do {
                let url = try await API.alistLink(name)
                phone.start(name, from: url)
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}

/// 存到手机的进度 / 结果
struct PhoneProgressLine: View {
    let item: PhoneDownloads.Item

    var body: some View {
        let via = item.viaAlist ? "（经 Alist）" : ""
        if let err = item.error {
            Text("存到手机失败\(via)：\(err)").font(.caption).foregroundColor(.red)
        } else if item.done {
            Text("已存到手机\(via)").font(.caption).foregroundColor(.green)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("正在存到手机\(via) \(fmtSize(Double(item.received))) / \(fmtSize(Double(item.total)))")
                    .font(.caption).foregroundColor(.accentColor)
                ProgressView(value: item.total > 0 ? Double(item.received) / Double(item.total) : 0)
            }
        }
    }
}

func shortDate(_ s: String?) -> String {
    String((s ?? "").prefix(16)).replacingOccurrences(of: "T", with: " ")
}

/// 底部短暂提示
struct ToastView: View {
    @Binding var text: String?

    var body: some View {
        if let t = text {
            Text(t)
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 12)
                .padding(.horizontal, 16)
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if text == t { text = nil }
                }
        }
    }
}
