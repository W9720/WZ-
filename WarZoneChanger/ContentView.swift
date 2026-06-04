import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager.shared
    @StateObject private var cardCodeManager = CardCodeManager.shared
    @State private var showingLocationPicker = false
    @State private var selectedLocation: SelectedLocation?
    @State private var cardCodeInput = ""
    @State private var showCardCodeInput = false
    @State private var showingSettings = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 0) {
                    // 顶部渐变背景
                    LinearGradient(gradient: Gradient(colors: [Color.accentColor, Color.purple]), startPoint: .top, endPoint: .bottom)
                        .frame(height: 200)
                        .overlay(
                            VStack(spacing: 16) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(.white)
                                
                                Text("战区精灵")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(.white)
                                
                                Text("轻松修改您的游戏战区")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white.opacity(0.8))
                            }
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
                        
                        // 操作按钮
                        Button(action: {
                            Task {
                                await handleStartModify()
                            }
                        }) {
                            Text(vpnManager.isConnected ? "停止修改" : "开始修改")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(vpnManager.isConnected ? Color.red : Color.accentColor)
                                .cornerRadius(16)
                                .shadow(color: vpnManager.isConnected ? Color.red.opacity(0.3) : Color.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .disabled(!canStartModify)
                        .opacity(canStartModify ? 1.0 : 0.5)
                        
                        // 开发者信息
                        VStack(spacing: 8) {
                            Text("开发者")
                                .font(.system(size: 14, weight: .semibold))
                            
                            HStack(spacing: 12) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 24))
                                    .foregroundColor(.orange)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("喜爱民谣")
                                        .font(.system(size: 16, weight: .medium))
                                    Text("愿每一首歌都能打动你")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(UIColor.systemBackground))
                        .cornerRadius(16)
                        .shadow(color: .gray.opacity(0.1), radius: 8, x: 0, y: 4)
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
        .onAppear {
            selectedLocation = LocationStore.shared.getSelectedLocation()
            vpnManager.checkStatus()
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
    }
    
    private var canStartModify: Bool {
        cardCodeManager.isLoggedIn && 
        cardCodeManager.cardInfo?.remainingCount ?? 0 > 0 && 
        selectedLocation != nil && 
        !vpnManager.isConnected
    }
    
    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: dateString) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateFormat = "yyyy-MM-dd"
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
                                    .font(.system(size: 14, fontDesign: .monospaced))
                            }
                            
                            HStack {
                                Text("创建时间")
                                    .font(.system(size: 14))
                                    .foregroundColor(.gray)
                                Spacer()
                                Text(formatDate(cardInfo.createdAt))
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
    
    private func formatDate(_ dateString: String) -> String {
        let formatter = ISO8601DateFormatter()
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
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 3