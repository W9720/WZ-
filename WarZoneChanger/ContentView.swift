import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var cardCodeManager = CardCodeManager.shared
    @StateObject private var announcementManager = AnnouncementManager.shared
    @StateObject private var certManager = CertificateManager.shared
    @State private var showingLocationPicker = false
    @State private var selectedLocation: SelectedLocation?
    @State private var cardCodeInput = ""
    @State private var showCardCodeInput = false
    @State private var showingSettings = false
    @State private var showingCertGuide = false
    @State private var currentAnnouncement: Announcement?
    @State private var showingAnnouncement = false
    @State private var showingLogs = false
    @State private var vpnLogs = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // 顶部渐变背景
                    LinearGradient(gradient: Gradient(colors: [Color.accentColor, Color.purple]), startPoint: .top, endPoint: .bottom)
                        .frame(height: min(UIScreen.main.bounds.height * 0.35, 220))
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: min(UIScreen.main.bounds.width * 0.12, 48)))
                                    .foregroundColor(.white)
                                
                                Text("战区精灵")
                                    .font(.system(size: min(UIScreen.main.bounds.width * 0.08, 32), weight: .bold))
                                    .minimumScaleFactor(0.7)
                                    .foregroundColor(.white)
                                
                                Text("轻松修改您的游戏战区")
                                    .font(.system(size: min(UIScreen.main.bounds.width * 0.04, 16)))
                                    .minimumScaleFactor(0.7)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 24)
                        )
                    
                    // 主内容区域
                    VStack(spacing: 20) {
                        // VPN状态卡片
                        VStack(spacing: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(vpnManager.isConnected ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                        .frame(width: 48, height: 48)
                                    
                                    Circle()
                                        .fill(vpnManager.isConnected ? Color.green : Color.red)
                                        .frame(width: 20, height: 20)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(vpnManager.isConnected ? "VPN已连接" : "VPN未连接")
                                        .font(.system(size: 18, weight: .semibold))
                                    Text(vpnManager.isConnected ? "战区修改中..." : "点击开始修改")
                                        .font(.system(size: 14))
                                        .foregroundColor(.gray)
                                }
                                
                                Spacer()
                                
                                Image(systemName: vpnManager.isConnected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 24))
                                    .foregroundColor(vpnManager.isConnected ? .green : .gray)
                            }
                        }
                        .padding(16)
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(16)
                        .shadow(color: .gray.opacity(0.1), radius: 8, x: 0, y: 4)
                        .padding(.horizontal, 16)
                        .padding(.top, -40)
                        
                        // 证书状态卡片
                        VStack(spacing: 12) {
                            HStack(alignment: .center, spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue.opacity(0.2))
                                        .frame(width: 48, height: 48)
                                    
                                    Image(systemName: "lock.shield.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.blue)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("HTTPS 证书")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("用于拦截 HTTPS 请求")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                }
                                
                                Spacer()
                                
                                Button(action: {
                                    showingCertGuide = true
                                }) {
                                    HStack(spacing: 4) {
                                        Text("安装引导")
                                            .font(.system(size: 14, weight: .medium))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                    }
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("📱 安装说明")
                                    .font(.system(size: 14, weight: .medium))
                                
                                Text("点击\"安装引导\"后，按以下步骤操作：")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("1. 点击安装引导 → 在 Safari 中打开证书")
                                        .font(.system(size: 11))
                                        .foregroundColor(.gray)
                                    Text("2. 在\"设置\"→\"通用\"→\"VPN与设备管理\"安装证书")
                                        .font(.system(size: 11))
                                        .foregroundColor(.gray)
                                    Text("3. 在\"设置\"→\"通用\"→\"关于本机\"开启证书信任")
                                        .font(.system(size: 11))
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(16)
                        .shadow(color: .gray.opacity(0.1), radius: 8, x: 0, y: 4)
                        .padding(.horizontal, 16)
                        
                        // 卡密信息卡片
                        if cardCodeManager.isLoggedIn, let cardInfo = cardCodeManager.cardInfo {
                            VStack(spacing: 12) {
                                HStack {
                                    Image(systemName: "ticket.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.orange)
                                    Text("卡密信息")
                                        .font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                    Button(action: { showingSettings = true }) {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 18))
                                            .foregroundColor(.gray)
                                    }
                                }
                                
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("剩余次数")
                                            .font(.system(size: 14))
                                            .foregroundColor(.gray)
                                        Spacer()
                                        Text("\(cardInfo.remainingCount) 次")
                                            .font(.system(size: 18, weight: .bold))
                                            .foregroundColor(cardInfo.remainingCount > 0 ? .green : .red)
                                    }
                                    
                                    HStack {
                                        Text("过期时间")
                                            .font(.system(size: 14))
                                            .foregroundColor(.gray)
                                        Spacer()
                                        Text(formatDate(cardInfo.expiresAt))
                                            .font(.system(size: 14))
                                            .foregroundColor(cardInfo.isExpired ? .red : .accentColor)
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(16)
                            .shadow(color: .gray.opacity(0.1), radius: 8, x: 0, y: 4)
                            .padding(.horizontal, 16)
                            
                        } else {
                            // 未登录卡密输入区域
                            VStack(spacing: 12) {
                                HStack {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.purple)
                                    Text("请输入卡密")
                                        .font(.system(size: 16, weight: .semibold))
                                    Spacer()
                                }
                                
                                TextField("请输入您的卡密", text: $cardCodeInput)
                                    .font(.system(size: 16))
                                    .padding(12)
                                    .background(Color(UIColor.systemGray6))
                                    .cornerRadius(8)
                                    .textContentType(.oneTimeCode)
                                
                                Button(action: {
                                    if !cardCodeInput.isEmpty {
                                        cardCodeManager.validateCardCode(code: cardCodeInput)
                                    }
                                }) {
                                    Text(cardCodeManager.isLoading ? "验证中..." : "验证卡密")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                        .background(Color.accentColor)
                                        .cornerRadius(8)
                                }
                                .disabled(cardCodeInput.isEmpty || cardCodeManager.isLoading)
                                .opacity(cardCodeInput.isEmpty || cardCodeManager.isLoading ? 0.5 : 1.0)
                                
                                if let error = cardCodeManager.errorMessage {
                                    Text(error)
                                        .font(.system(size: 14))
                                        .foregroundColor(.red)
                                        .multilineTextAlignment(.center)
                                }
                            }
                            .padding(16)
                            .background(Color(UIColor.systemBackground))
                            .cornerRadius(16)
                            .shadow(color: .gray.opacity(0.1), radius: 8, x: 0, y: 4)
                            .padding(.horizontal, 16)
                        }
                        
                        // 战区选择区域
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "map.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.blue)
                                Text("目标战区")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            
                            VStack(spacing: 8) {
                                Text(selectedLocation != nil ? "\(selectedLocation!.province) \(selectedLocation!.city)" : "未选择战区")
                                    .font(.system(size: 16))
                                    .foregroundColor(selectedLocation != nil ? .primary : .gray)
                                
                                Button(action: {
                                    showingLocationPicker = true
                                }) {
                                    Text("选择战区")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.accentColor)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 44)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.accentColor, lineWidth: 1)
                                        )
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(16)
                        .shadow(color: .gray.opacity(0.1), radius: 8, x: 0, y: 4)
                        .padding(.horizontal, 16)
                        
                        // VPN错误提示
                        if let error = vpnManager.errorMessage {
                            VStack(spacing: 8) {
                                HStack {
                                    Image(systemName: "exclamationmark.circle")
                                        .font(.system(size: 18))
                                        .foregroundColor(.red)
                                    Text("错误提示")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                Text(error)
                                    .font(.system(size: 14))
                                    .foregroundColor(.red)
                            }
                            .padding(16)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                        }
                        
                        // VPN 日志查看
                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 18))
                                    .foregroundColor(.blue)
                                Text("VPN 诊断日志")
                                    .font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Button(showingLogs ? "隐藏" : "查看") {
                                    showingLogs.toggle()
                                    if showingLogs {
                                        refreshLogs()
                                    }
                                }
                                .font(.system(size: 14))
                                .foregroundColor(.accentColor)
                            }
                            
                            if showingLogs {
                                ScrollView {
                                    Text(vpnLogs.isEmpty ? "暂无日志" : vpnLogs)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 200)
                                .padding(8)
                                .background(Color(UIColor.systemGray6))
                                .cornerRadius(8)
                                
                                HStack(spacing: 12) {
                                    Button("刷新日志") {
                                        refreshLogs()
                                    }
                                    .font(.system(size: 12))
                                    .foregroundColor(.accentColor)
                                    
                                    Button("一键复制") {
                                        UIPasteboard.general.string = vpnLogs
                                    }
                                    .font(.system(size: 12))
                                    .foregroundColor(.accentColor)
                                    .disabled(vpnLogs.isEmpty || vpnLogs.hasPrefix("暂无日志"))
                                    
                                    Button("清空日志") {
                                        clearLogs()
                                    }
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(16)
                        .shadow(color: .gray.opacity(0.1), radius: 8, x: 0, y: 4)
                        .padding(.horizontal, 16)
                        
                        // 操作按钮
                        if vpnManager.isConnected {
                            Button(action: {
                                vpnManager.stopVPN()
                            }) {
                                Text("停止修改")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .background(Color.red)
                                    .cornerRadius(16)
                                    .shadow(color: Color.red.opacity(0.3), radius: 8, x: 0, y: 4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .disabled(!canStopModify)
                            .opacity(canStopModify ? 1.0 : 0.5)
                        } else {
                            Button(action: {
                                Task {
                                    await handleStartModify()
                                }
                            }) {
                                Text(vpnManager.isConnecting ? "连接中..." : "开始修改")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 56)
                                    .background(Color.accentColor)
                                    .cornerRadius(16)
                                    .shadow(color: Color.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .disabled(!canStartModify)
                            .opacity(canStartModify ? 1.0 : 0.5)
                        }
                        
                        // 作者信息
                        VStack(spacing: 12) {
                            HStack {
                                Image(systemName: "person.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(.purple)
                                Text("作者信息")
                                    .font(.system(size: 16, weight: .semibold))
                                Spacer()
                            }
                            
                            VStack(spacing: 4) {
                                Text("喜爱民谣")
                                    .font(.system(size: 16, weight: .medium))
                                Text("我欲见你 又何惧一两个春秋")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(16)
                        .shadow(color: .gray.opacity(0.1), radius: 8, x: 0, y: 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.gray.opacity(0.1), lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationBarHidden(true)
            .background(Color(UIColor.systemGray5))
        }
        .sheet(isPresented: $showingLocationPicker) {
            LocationPickerView(selectedLocation: $selectedLocation)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingCertGuide) {
            CertificateGuideView()
        }
        .onAppear {
            selectedLocation = LocationStore.shared.getSelectedLocation()
            vpnManager.checkStatus()
            fetchAnnouncements()
        }
        .onChange(of: selectedLocation) { newLocation in
            if let loc = newLocation {
                LocationStore.shared.saveLocation(
                    adcode: loc.adcode,
                    name: loc.name,
                    province: loc.province,
                    city: loc.city
                )
            }
        }
        .onChange(of: announcementManager.unreadAnnouncements) { announcements in
            if let first = announcements.first, !showingAnnouncement {
                currentAnnouncement = first
                showingAnnouncement = true
            }
        }
        .alert(isPresented: $showingAnnouncement) {
            if let ann = currentAnnouncement {
                return Alert(
                    title: Text(ann.title),
                    message: Text(ann.content),
                    dismissButton: .default(Text("我知道了")) {
                        if let id = currentAnnouncement?.id {
                            announcementManager.markAsRead(announcementId: id)
                        }
                    }
                )
            }
            return Alert(title: Text("公告"))
        }
    }
    
    private func fetchAnnouncements() {
        announcementManager.fetchUnreadAnnouncements()
    }
    
    private var canStartModify: Bool {
        cardCodeManager.isLoggedIn && 
        cardCodeManager.cardInfo?.remainingCount ?? 0 > 0 && 
        selectedLocation != nil && 
        !vpnManager.isConnected &&
        !vpnManager.isConnecting
    }
    
    private var canStopModify: Bool {
        vpnManager.isConnected
    }
    
    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            return outputFormatter.string(from: date)
        }
        return dateString
    }
    
    private func handleStartModify() async {
        if !cardCodeManager.isLoggedIn {
            vpnManager.errorMessage = "请先输入卡密验证"
            return
        }
        
        if let cardInfo = cardCodeManager.cardInfo, cardInfo.remainingCount <= 0 {
            vpnManager.errorMessage = "卡密剩余次数不足"
            return
        }
        
        do {
            let success = try await cardCodeManager.deductCount()
            if success {
                vpnManager.startVPN()
            }
        } catch {
            vpnManager.errorMessage = error.localizedDescription
        }
    }
    
    private func refreshLogs() {
        var logs = ""
        
        // 方式1: 从 UserDefaults 读取
        if let defaults = UserDefaults(suiteName: "group.com.warzone.changer") {
            if let udLogs = defaults.string(forKey: "vpn_logs"), !udLogs.isEmpty {
                logs = udLogs
            }
        }
        
        // 方式2: 从共享文件读取（作为回退）
        if logs.isEmpty {
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.warzone.changer") {
                let fileURL = containerURL.appendingPathComponent("vpn_diag.log")
                if let fileLogs = try? String(contentsOf: fileURL, encoding: .utf8), !fileLogs.isEmpty {
                    logs = fileLogs
                }
            }
        }
        
        vpnLogs = logs.isEmpty ? "暂无日志 — App Group 可能不可访问或扩展未运行" : logs
    }
    
    private func clearLogs() {
        if let defaults = UserDefaults(suiteName: "group.com.warzone.changer") {
            defaults.removeObject(forKey: "vpn_logs")
            defaults.synchronize()
        }
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.warzone.changer") {
            let fileURL = containerURL.appendingPathComponent("vpn_diag.log")
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        vpnLogs = ""
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cardCodeManager = CardCodeManager.shared
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if let cardInfo = cardCodeManager.cardInfo {
                    VStack(spacing: 12) {
                        Text("卡密详情")
                            .font(.system(size: 18, weight: .semibold))
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("卡密")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                                Spacer()
                                Text(cardInfo.code)
                                    .font(.system(size: 14))
                            }
                            
                            HStack {
                                Text("创建时间")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                                Spacer()
                                Text(formatDateWithTime(cardInfo.createdAt))
                                    .font(.system(size: 14))
                            }
                        }
                        .padding(12)
                        .background(Color(UIColor.systemGray6))
                        .cornerRadius(8)
                    }
                    .padding(.horizontal, 16)
                }
                
                Button(action: {
                    cardCodeManager.logout()
                    dismiss()
                }) {
                    Text("退出登录")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
                .padding(.horizontal, 16)
                
                Spacer()
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formatDateWithTime(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            return outputFormatter.string(from: date)
        }
        return dateString
    }
}

struct Region: Codable, Hashable {
    let adcode: Int
    let shortName: String
    let fullName: String
    let list: [Region]?
    
    static func == (lhs: Region, rhs: Region) -> Bool {
        return lhs.adcode == rhs.adcode
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(adcode)
    }
}

class RegionData {
    static let shared = RegionData()
    
    var allRegions: [Region] = []
    
    private init() {
        loadRegions()
    }
    
    private func loadRegions() {
        guard let url = Bundle.main.url(forResource: "warzone", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("Failed to load warzone.json")
            return
        }
        
        do {
            allRegions = try JSONDecoder().decode([Region].self, from: data)
        } catch {
            print("Failed to parse warzone.json: \(error)")
        }
    }
}

struct LocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedLocation: SelectedLocation?
    
    @State private var selectedProvince: Region?
    @State private var selectedCity: Region?
    @State private var selectedDistrict: Region?
    
    private let allRegions = RegionData.shared.allRegions
    
    private var cities: [Region] {
        selectedProvince?.list ?? []
    }
    
    private var districts: [Region] {
        selectedCity?.list ?? []
    }
    
    private var selectedAdcode: String {
        if let district = selectedDistrict {
            return "\(district.adcode)"
        } else if let city = selectedCity {
            return "\(city.adcode)"
        } else if let province = selectedProvince {
            return "\(province.adcode)"
        }
        return ""
    }
    
    private var selectedName: String {
        if let district = selectedDistrict {
            return district.shortName
        } else if let city = selectedCity {
            return city.shortName
        } else if let province = selectedProvince {
            return province.shortName
        }
        return ""
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // 省份选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("省份")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 16)
                    
                    Picker("省份", selection: $selectedProvince) {
                        Text("请选择省份").tag(nil as Region?)
                        ForEach(allRegions, id: \.adcode) { province in
                            Text(province.shortName).tag(province as Region?)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedProvince == nil ? Color.gray.opacity(0.3) : Color.accentColor, lineWidth: 1)
                    )
                    .onChange(of: selectedProvince) { _ in
                        selectedCity = nil
                        selectedDistrict = nil
                    }
                }
                
                // 城市选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("城市")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 16)
                    
                    Picker("城市", selection: $selectedCity) {
                        Text("请选择城市").tag(nil as Region?)
                        ForEach(cities, id: \.adcode) { city in
                            Text(city.shortName).tag(city as Region?)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedCity == nil ? Color.gray.opacity(0.3) : Color.accentColor, lineWidth: 1)
                    )
                    .disabled(selectedProvince == nil)
                    .opacity(selectedProvince == nil ? 0.5 : 1.0)
                    .onChange(of: selectedCity) { _ in
                        selectedDistrict = nil
                    }
                }
                
                // 区县选择
                VStack(alignment: .leading, spacing: 8) {
                    Text("区县")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 16)
                    
                    Picker("区县", selection: $selectedDistrict) {
                        Text("请选择区县").tag(nil as Region?)
                        ForEach(districts, id: \.adcode) { district in
                            Text(district.shortName).tag(district as Region?)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 16)
                    .frame(height: 48)
                    .background(Color(UIColor.systemBackground))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(selectedDistrict == nil ? Color.gray.opacity(0.3) : Color.accentColor, lineWidth: 1)
                    )
                    .disabled(selectedCity == nil)
                    .opacity(selectedCity == nil ? 0.5 : 1.0)
                }
                
                // 位置信息显示
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "location.circle")
                            .foregroundColor(.orange)
                        Text("位置信息")
                            .font(.system(size: 14))
                    }
                    
                    if selectedProvince != nil {
                        Text("省份: \(selectedProvince!.shortName)")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    if selectedCity != nil {
                        Text("城市: \(selectedCity!.shortName)")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    if selectedDistrict != nil {
                        Text("区县: \(selectedDistrict!.shortName)")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    if !selectedAdcode.isEmpty {
                        Text("城市编码: \(selectedAdcode)")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(UIColor.systemGray6))
                .cornerRadius(8)
                .padding(.horizontal, 16)
                
                Spacer()
                
                // 确认按钮
                Button(action: {
                    if selectedProvince != nil {
                        selectLocation()
                    }
                }) {
                    Text("确认选择")
                        .foregroundColor(.white)
                        .padding()
                }
                .background(Color.accentColor)
                .cornerRadius(12)
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
    }
    
    private func selectLocation() {
        if let province = selectedProvince {
            let location = SelectedLocation(
                adcode: selectedAdcode,
                name: selectedName,
                province: province.shortName,
                city: selectedCity?.shortName ?? ""
            )
            selectedLocation = location
            dismiss()
        }
    }
}

struct CertificateGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var certManager = CertificateManager.shared
    @State private var step = 0
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 16) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("证书安装指南")
                            .font(.system(size: 22, weight: .bold))
                        
                        Text("为了能够拦截 HTTPS 请求，您需要安装并信任本应用的 CA 证书。")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding(.top, 20)
                    
                    VStack(spacing: 12) {
                        StepView(number: 1, title: "打开证书", description: "点击下方按钮，在 Safari 中打开证书文件", isActive: step >= 0, isCompleted: step > 0)
                        
                        StepView(number: 2, title: "安装证书", description: "在\"设置\"→\"通用\"→\"VPN与设备管理\"中安装证书", isActive: step >= 1, isCompleted: step > 1)
                        
                        StepView(number: 3, title: "信任证书", description: "在\"设置\"→\"通用\"→\"关于本机\"→\"证书信任设置\"中开启完全信任", isActive: step >= 2, isCompleted: step > 2)
                    }
                    .padding(.horizontal, 16)
                    
                    VStack(spacing: 12) {
                        Button(action: {
                            certManager.openCertificateInSafari()
                        }) {
                            HStack {
                                Image(systemName: "safari")
                                Text("在 Safari 中打开证书")
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.blue)
                            .cornerRadius(12)
                        }
                        
                        HStack(spacing: 12) {
                            Button(action: {
                                certManager.shareCertificate()
                            }) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("分享证书")
                                }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            }
                            
                            Button(action: {
                                certManager.copyCertificateToPasteboard()
                            }) {
                                HStack {
                                    Image(systemName: "doc.on.doc")
                                    Text("复制证书")
                                }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                            }
                        }
                        
                        HStack(spacing: 12) {
                            Button(action: {
                                if step < 3 {
                                    step += 1
                                }
                            }) {
                                Text("标记当前步骤完成")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.blue)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.blue.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            
                            Button(action: {
                                step = 0
                            }) {
                                Text("重置步骤")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.gray)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.gray.opacity(0.1))
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("⚠️ 重要提示")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.orange)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("• 如果王者荣耀使用 HTTP（80端口），无需安装证书")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                            Text("• 如果王者荣耀使用 HTTPS（443端口），必须安装此证书")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                            Text("• 即使安装了证书，证书钉扎（Certificate Pinning）仍可能导致拦截失败")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                            Text("• 此证书仅用于本应用的 VPN 拦截功能，不会影响其他应用")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(16)
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("证书信息")
                            .font(.system(size: 14, weight: .semibold))
                        
                        Text(certManager.getCertificateInfo())
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color(UIColor.systemGray6))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)
                    
                    Spacer()
                }
            }
            .navigationTitle("证书安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct StepView: View {
    let number: Int
    let title: String
    let description: String
    let isActive: Bool
    let isCompleted: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green : (isActive ? Color.blue : Color.gray.opacity(0.3)))
                    .frame(width: 32, height: 32)
                
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isActive ? .primary : .gray)
                
                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }
            
            Spacer()
        }
        .padding(12)
        .background(isActive ? Color.blue.opacity(0.05) : Color(UIColor.systemGray6))
        .cornerRadius(10)
    }
}