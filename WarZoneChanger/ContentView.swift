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
    
    @State private var searchText = ""
    @State private var selectedProvince: Region?
    @State private var selectedCity: Region?
    
    private let allRegions = RegionData.shared.allRegions
    
    private var filteredProvinces: [Region] {
        if searchText.isEmpty {
            return allRegions
        }
        return allRegions.filter { $0.shortName.contains(searchText) }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                TextField("搜索省份...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                
                HStack(spacing: 0) {
                    List(filteredProvinces, id: \.adcode) { province in
                        Button(action: {
                            selectedProvince = province
                            selectedCity = nil
                        }) {
                            HStack {
                                Text(province.shortName)
                                    .foregroundColor(selectedProvince?.adcode == province.adcode ? .accentColor : .primary)
                                Spacer()
                                if selectedProvince?.adcode == province.adcode {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                    .frame(maxWidth: .infinity)
                    
                    if let province = selectedProvince, let cities = province.list {
                        Divider()
                        List(cities, id: \.adcode) { city in
                            Button(action: {
                                selectedCity = city
                            }) {
                                HStack {
                                    Text(city.shortName)
                                        .foregroundColor(selectedCity?.adcode == city.adcode ? .accentColor : .primary)
                                    Spacer()
                                    if selectedCity?.adcode == city.adcode {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                        .listStyle(PlainListStyle())
                        .frame(maxWidth: .infinity)
                    }
                    
                    if let city = selectedCity, let districts = city.list, !districts.isEmpty {
                        Divider()
                        List(districts, id: \.adcode) { district in
                            Button(action: {
                                selectLocation(
                                    adcode: "\(district.adcode)",
                                    name: district.shortName,
                                    province: selectedProvince!.shortName,
                                    city: city.shortName
                                )
                            }) {
                                Text(district.shortName)
                            }
                        }
                        .listStyle(PlainListStyle())
                        .frame(maxWidth: .infinity)
                    } else if let city = selectedCity {
                        Divider()
                        List {
                            Button(action: {
                                selectLocation(
                                    adcode: "\(city.adcode)",
                                    name: city.shortName,
                                    province: selectedProvince!.shortName,
                                    city: city.shortName
                                )
                            }) {
                                Text("点击直接选择市级战区")
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .listStyle(PlainListStyle())
                        .frame(maxWidth: .infinity)
                    }
                }
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
    }
    
    private func selectLocation(adcode: String, name: String, province: String, city: String) {
        selectedLocation = SelectedLocation(
            adcode: adcode,
            name: name,
            province: province,
            city: city
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
