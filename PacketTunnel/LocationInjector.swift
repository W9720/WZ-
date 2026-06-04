import Foundation

class LocationInjector {
    static let shared = LocationInjector()
    
    private let targetHost = "apis.map.qq.com"
    private let targetPath = "/ws/geocoder/v1"
    
    private init() {}
    
    func isTargetRequest(host: String?, path: String?) -> Bool {
        guard let host = host, let path = path else {
            return false
        }
        return host.contains(targetHost) && path.contains(targetPath)
    }
    
    func buildFakeResponse(adcode: String, regionName: String) -> String {
        let location = getLocationByAdcode(adcode: adcode)
        let province = getProvinceByAdcode(adcode: adcode)
        let city = getCityByAdcode(adcode: adcode)
        let district = regionName
        
        let response: [String: Any] = [
            "status": 0,
            "message": "Success",
            "request_id": generateRequestId(),
            "result": [
                "address_components": [
                    "nation": "中国",
                    "province": province,
                    "city": city,
                    "district": district,
                    "street": "",
                    "street_number": ""
                ],
                "ad_info": [
                    "nation_code": "156",
                    "adcode": adcode,
                    "city_code": String(adcode.prefix(4)) + "00",
                    "name": regionName,
                    "location": [
                        "lat": location.lat,
                        "lng": location.lng
                    ],
                    "nation": "中国",
                    "province": province,
                    "city": city,
                    "district": district
                ],
                "location": [
                    "lat": location.lat,
                    "lng": location.lng
                ],
                "formatted_addresses": [
                    "recommend": "",
                    "rough": ""
                ],
                "address_reference": [:]
            ]
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: response, options: .prettyPrinted)
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            print("Failed to build fake response: \(error)")
            return ""
        }
    }
    
    private func getLocationByAdcode(adcode: String) -> (lat: Double, lng: Double) {
        let prefix = String(adcode.prefix(2))
        
        switch prefix {
        case "11": return (39.9042, 116.4074)
        case "31": return (31.2304, 121.4737)
        case "44": return (23.1291, 113.2644)
        case "33": return (30.2741, 120.1551)
        case "32": return (32.0617, 118.7778)
        case "51": return (30.5728, 104.0668)
        case "50": return (29.5630, 106.5516)
        case "42": return (30.5928, 114.3055)
        case "43": return (28.2282, 112.9388)
        case "35": return (26.0745, 119.2965)
        case "36": return (28.6820, 115.8579)
        case "34": return (31.8612, 117.2830)
        case "37": return (36.6683, 116.9972)
        case "41": return (34.7472, 113.6254)
        case "13": return (38.0428, 114.5149)
        case "14": return (37.8706, 112.5489)
        case "21": return (41.8057, 123.4315)
        case "22": return (43.8868, 125.3245)
        case "23": return (45.8038, 126.5350)
        case "15": return (40.8183, 111.7656)
        case "61": return (34.2658, 108.9541)
        case "62": return (36.0594, 103.8343)
        case "63": return (36.6171, 101.7782)
        case "64": return (38.4872, 106.2309)
        case "65": return (43.7930, 87.6271)
        case "53": return (25.0389, 102.7183)
        case "52": return (26.6470, 106.6302)
        case "45": return (22.8170, 108.3665)
        case "46": return (20.0174, 110.3492)
        case "54": return (29.6500, 91.1000)
        default: return (39.9042, 116.4074)
        }
    }
    
    private func getProvinceByAdcode(adcode: String) -> String {
        let prefix = String(adcode.prefix(2))
        
        switch prefix {
        case "11": return "北京市"
        case "31": return "上海市"
        case "44": return "广东省"
        case "33": return "浙江省"
        case "32": return "江苏省"
        case "51": return "四川省"
        case "50": return "重庆市"
        case "42": return "湖北省"
        case "43": return "湖南省"
        case "35": return "福建省"
        case "36": return "江西省"
        case "34": return "安徽省"
        case "37": return "山东省"
        case "41": return "河南省"
        case "13": return "河北省"
        case "14": return "山西省"
        case "21": return "辽宁省"
        case "22": return "吉林省"
        case "23": return "黑龙江省"
        case "15": return "内蒙古自治区"
        case "61": return "陕西省"
        case "62": return "甘肃省"
        case "63": return "青海省"
        case "64": return "宁夏回族自治区"
        case "65": return "新疆维吾尔自治区"
        case "53": return "云南省"
        case "52": return "贵州省"
        case "45": return "广西壮族自治区"
        case "46": return "海南省"
        case "54": return "西藏自治区"
        default: return "未知"
        }
    }
    
    private func getCityByAdcode(adcode: String) -> String {
        return "城市"
    }
    
    private func generateRequestId() -> String {
        let chars = "abcdef0123456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}
