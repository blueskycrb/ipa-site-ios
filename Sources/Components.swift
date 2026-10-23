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

/// 「安装」：向服务器要 itms-services 安装链接并打开，iOS 会弹出安装确认
struct InstallButton: View {
    let name: String
    @Binding var toast: String?
    @Environment(\.openURL) private var openURL
    @State private var working = false

    var body: some View {
        Button(working ? "准备中…" : "安装") {
            Task {
                working = true
                do {
                    let (url, source) = try await API.installURL(name)
                    toast = (source == "alist" ? "从 Alist 安装" : "从服务器安装") + "：在弹窗里点「安装」，再回到主屏幕看进度"
                    openURL(url)
                } catch {
                    toast = error.localizedDescription
                }
                working = false
            }
        }
        .buttonStyle(.bordered)
        .disabled(working)
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
