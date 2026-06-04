import Foundation

struct SelectedLocation: Codable, Equatable {
    let adcode: String
    let name: String
    let province: String
    let city: String
    
    var displayName: String {
        return "\(province) \(city) \(name)"
    }
}

class LocationStore {
    static let shared = LocationStore()
    
    private let appGroupId = "group.com.warzone.changer"
    private let keyAdcode = "target_adcode"
    private let keyName = "target_name"
    private let keyProvince = "target_province"
    private let keyCity = "target_city"
    
    private var defaults: UserDefaults {
        return UserDefaults(suiteName: appGroupId) ?? UserDefaults.standard
    }
    
    private init() {}
    
    func saveLocation(adcode: String, name: String, province: String, city: String) {
        defaults.set(adcode, forKey: keyAdcode)
        defaults.set(name, forKey: keyName)
        defaults.set(province, forKey: keyProvince)
        defaults.set(city, forKey: keyCity)
        defaults.synchronize()
    }
    
    func getSelectedLocation() -> SelectedLocation? {
        guard let adcode = defaults.string(forKey: keyAdcode) else {
            return nil
        }
        let name = defaults.string(forKey: keyName) ?? ""
        let province = defaults.string(forKey: keyProvince) ?? ""
        let city = defaults.string(forKey: keyCity) ?? ""
        return SelectedLocation(adcode: adcode, name: name, province: province, city: city)
    }
    
    func hasLocation() -> Bool {
        return defaults.string(forKey: keyAdcode) != nil
    }
    
    func clear() {
        defaults.removeObject(forKey: keyAdcode)
        defaults.removeObject(forKey: keyName)
        defaults.removeObject(forKey: keyProvince)
        defaults.removeObject(forKey: keyCity)
        defaults.synchronize()
    }
}
