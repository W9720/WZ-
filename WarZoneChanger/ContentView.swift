import SwiftUI
import NetworkExtension

struct ContentView: View {
    @StateObject private var vpnManager = VPNManager.shared
    @State private var showingLocationPicker = false
    @State private var selectedLocation: SelectedLocation?
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Text("战区修改器")
                    .font(.system(size: 28, weight: .bold))
                    .padding(.top, 32)
                
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(vpnManager.isConnected ? Color.green : Color.red)
                            .frame(width: 12, height: 12)
                        Text(vpnManager.isConnected ? "运行中" : "已停止")
                            .font(.system(size: 18))
                    }
                }
                .padding(.top, 16)
                
                Divider()
                    .padding(.vertical, 24)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("目标战区")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                    
                    Text(locationText)
                        .font(.system(size: 16))
                    
                    Button(action: {
                        showingLocationPicker = true
                    }) {
                        Text("选择战区")
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor, lineWidth: 1)
                            )
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                
                if let error = vpnManager.errorMessage {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.red)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .multilineTextAlignment(.center)
                }
                
                Spacer()
                
                Button(action: {
                    vpnManager.toggleVPN()
                }) {
                    Text(vpnManager.isConnected ? "停止修改" : "开始修改")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(vpnManager.isConnected ? Color.red : Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .disabled(selectedLocation == nil && !vpnManager.isConnected)
                .opacity(selectedLocation == nil && !vpnManager.isConnected ? 0.5 : 1.0)
            }
            .navigationBarHidden(true)
        }
        .sheet(isPresented: $showingLocationPicker) {
            LocationPickerView(selectedLocation: $selectedLocation)
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
    
    private var locationText: String {
        if let loc = selectedLocation {
            return "当前战区: \(loc.province) \(loc.city) (\(loc.adcode))"
        }
        return "未选择战区"
    }
}

struct Region: Codable {
    let adcode: Int
    let shortName: String
    let fullName: String
    let list: [Region]?
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
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.accentColor)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .disabled(selectedProvince == nil)
                .opacity(selectedProvince == nil ? 0.5 : 1.0)
            }
            .navigationTitle("选择战区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // 初始化已选择的位置
            if let loc = selectedLocation {
                // 尝试找到对应的省份、城市、区县
                let adcodeInt = Int(loc.adcode) ?? 0
                let provinceCode = adcodeInt / 10000 * 10000
                let cityCode = adcodeInt / 100 * 100
                
                selectedProvince = allRegions.first { $0.adcode == provinceCode }
                
                if let province = selectedProvince {
                    if cityCode != provinceCode {
                        selectedCity = province.list?.first { $0.adcode == cityCode }
                        
                        if let city = selectedCity, adcodeInt != cityCode {
                            selectedDistrict = city.list?.first { $0.adcode == adcodeInt }
                        }
                    }
                }
            }
        }
    }
    
    private func selectLocation() {
        let provinceName = selectedProvince!.shortName
        let cityName = selectedCity?.shortName ?? ""
        let districtName = selectedDistrict?.shortName ?? ""
        
        let displayName: String
        if let district = selectedDistrict {
            displayName = district.shortName
        } else if let city = selectedCity {
            displayName = city.shortName
        } else {
            displayName = provinceName
        }
        
        selectedLocation = SelectedLocation(
            adcode: selectedAdcode,
            name: displayName,
            province: provinceName,
            city: cityName.isEmpty ? provinceName : cityName
        )
        dismiss()
    }
}

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
    @Published var isConnected = false
    @Published var errorMessage: String?
    
    private var manager: NETunnelProviderManager?
    
    private init() {}
    
    func checkStatus() {
        errorMessage = nil
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Failed to load VPN managers: \(error)")
                return
            }
            
            self.manager = managers?.first
            DispatchQueue.main.async {
                self.isConnected = self.manager?.connection.status == .connected
            }
        }
    }
    
    func toggleVPN() {
        if isConnected {
            stopVPN()
        } else {
            startVPN()
        }
    }
    
    private func startVPN() {
        errorMessage = nil
        
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Failed to load VPN managers: \(error)")
                DispatchQueue.main.async {
                    self.errorMessage = "无法加载VPN配置: \(error.localizedDescription)"
                }
                return
            }
            
            let vpnManager: NETunnelProviderManager
            if let existing = managers?.first {
                vpnManager = existing
            } else {
                vpnManager = NETunnelProviderManager()
                vpnManager.localizedDescription = "战区修改器"
                
                let protocolConfig = NETunnelProviderProtocol()
                protocolConfig.providerBundleIdentifier = "com.warzone.changer.PacketTunnel"
                protocolConfig.serverAddress = "10.0.0.1"
                vpnManager.protocolConfiguration = protocolConfig
            }
            
            vpnManager.isEnabled = true
            
            vpnManager.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                
                if let error = error {
                    print("Failed to save VPN config: \(error)")
                    DispatchQueue.main.async {
                        self.errorMessage = "无法保存VPN配置: \(error.localizedDescription)"
                    }
                    return
                }
                
                vpnManager.loadFromPreferences { [weak self] error in
                    guard let self = self else { return }
                    
                    if let error = error {
                        print("Failed to load VPN config: \(error)")
                        DispatchQueue.main.async {
                            self.errorMessage = "无法加载VPN配置: \(error.localizedDescription)"
                        }
                        return
                    }
                    
                    do {
                        try vpnManager.connection.startVPNTunnel()
                        DispatchQueue.main.async {
                            self.isConnected = true
                            self.manager = vpnManager
                        }
                    } catch {
                        print("Failed to start VPN: \(error)")
                        DispatchQueue.main.async {
                            self.errorMessage = "VPN启动失败，请检查系统设置是否允许VPN"
                        }
                    }
                }
            }
        }
    }
    
    private func stopVPN() {
        manager?.connection.stopVPNTunnel()
        DispatchQueue.main.async {
            self.isConnected = false
            self.errorMessage = nil
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
