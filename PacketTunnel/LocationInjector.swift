import Foundation

class LocationInjector {
    static let shared = LocationInjector()
    
    private init() {}
    
    enum APIType {
        case reverseGeocoder
        case geocoder
        case districtList
        case ipLocation
        case unknown
    }
    
    func detectAPIType(_ request: String) -> APIType {
        if request.contains("/ws/geocoder/v1/reverse") {
            return .reverseGeocoder
        } else if request.contains("/ws/geocoder/v1") {
            return .geocoder
        } else if request.contains("/ws/district/v1/list") {
            return .districtList
        } else if request.contains("/ws/location/v1/ip") {
            return .ipLocation
        }
        return .unknown
    }
    
    func buildFakeResponse(for type: APIType, adcode: String, regionName: String) -> String {
        switch type {
        case .reverseGeocoder:
            return buildReverseGeocoderResponse(adcode: adcode, regionName: regionName)
        case .geocoder:
            return buildGeocoderResponse(adcode: adcode, regionName: regionName)
        case .districtList:
            return buildDistrictListResponse()
        case .ipLocation:
            return buildIPLocationResponse(adcode: adcode, regionName: regionName)
        case .unknown:
            return buildReverseGeocoderResponse(adcode: adcode, regionName: regionName)
        }
    }
    
    private func buildReverseGeocoderResponse(adcode: String, regionName: String) -> String {
        let location = getLocationByAdcode(adcode: adcode)
        let province = getProvinceByAdcode(adcode: adcode)
        let city = getCityByAdcode(adcode: adcode)
        let district = regionName
        let formattedAddress = "\(province)\(city)\(district)"
        let fullName = "中国,\(province),\(city),\(district)"
        
        let response: [String: Any] = [
            "status": 0,
            "message": "Success",
            "request_id": generateRequestId(),
            "result": [
                "location": [
                    "lat": location.lat,
                    "lng": location.lng
                ],
                "address": formattedAddress,
                "address_component": [
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
                    "name": fullName,
                    "location": [
                        "lat": location.lat,
                        "lng": location.lng
                    ],
                    "nation": "中国",
                    "province": province,
                    "city": city,
                    "district": district
                ]
            ]
        ]
        
        return toJSON(response)
    }
    
    private func buildGeocoderResponse(adcode: String, regionName: String) -> String {
        let location = getLocationByAdcode(adcode: adcode)
        let province = getProvinceByAdcode(adcode: adcode)
        let city = getCityByAdcode(adcode: adcode)
        let district = regionName
        
        let response: [String: Any] = [
            "status": 0,
            "message": "query ok",
            "request_id": generateRequestId(),
            "result": [
                "title": regionName,
                "location": [
                    "lat": location.lat,
                    "lng": location.lng
                ],
                "ad_info": [
                    "adcode": adcode,
                    "province": province,
                    "city": city,
                    "district": district
                ],
                "address_components": [
                    "province": province,
                    "city": city,
                    "district": district,
                    "street": "",
                    "street_number": ""
                ],
                "similarity": 0.8,
                "deviation": 1000,
                "reliability": 1,
                "level": 2
            ]
        ]
        
        return toJSON(response)
    }
    
    private func buildDistrictListResponse() -> String {
        let response: [String: Any] = [
            "status": 0,
            "message": "query ok",
            "request_id": generateRequestId(),
            "data_version": "2023",
            "result": buildAllProvinces()
        ]
        
        return toJSON(response)
    }
    
    private func buildIPLocationResponse(adcode: String, regionName: String) -> String {
        let location = getLocationByAdcode(adcode: adcode)
        let province = getProvinceByAdcode(adcode: adcode)
        let city = getCityByAdcode(adcode: adcode)
        
        let response: [String: Any] = [
            "status": 0,
            "message": "query ok",
            "request_id": generateRequestId(),
            "result": [
                "ip": "127.0.0.1",
                "location": [
                    "lat": location.lat,
                    "lng": location.lng
                ],
                "ad_info": [
                    "nation": "中国",
                    "province": province,
                    "city": city,
                    "district": regionName,
                    "adcode": adcode
                ]
            ]
        ]
        
        return toJSON(response)
    }
    
    private func buildAllProvinces() -> [[String: Any]] {
        let provinces = [
            ("110000", "北京市"),
            ("120000", "天津市"),
            ("130000", "河北省"),
            ("140000", "山西省"),
            ("150000", "内蒙古自治区"),
            ("210000", "辽宁省"),
            ("220000", "吉林省"),
            ("230000", "黑龙江省"),
            ("310000", "上海市"),
            ("320000", "江苏省"),
            ("330000", "浙江省"),
            ("340000", "安徽省"),
            ("350000", "福建省"),
            ("360000", "江西省"),
            ("370000", "山东省"),
            ("410000", "河南省"),
            ("420000", "湖北省"),
            ("430000", "湖南省"),
            ("440000", "广东省"),
            ("450000", "广西壮族自治区"),
            ("460000", "海南省"),
            ("500000", "重庆市"),
            ("510000", "四川省"),
            ("520000", "贵州省"),
            ("530000", "云南省"),
            ("540000", "西藏自治区"),
            ("610000", "陕西省"),
            ("620000", "甘肃省"),
            ("630000", "青海省"),
            ("640000", "宁夏回族自治区"),
            ("650000", "新疆维吾尔自治区"),
            ("710000", "台湾省"),
            ("810000", "香港特别行政区"),
            ("820000", "澳门特别行政区")
        ]
        
        return provinces.map { (adcode, name) in
            let loc = getLocationByAdcode(adcode: adcode)
            return [
                "id": Int(adcode.prefix(2)) ?? 0,
                "name": name,
                "fullname": name,
                "pinyin": [],
                "level": 1,
                "location": [
                    "lat": loc.lat,
                    "lng": loc.lng
                ],
                "adcode": adcode,
                "cidx": [0, 1]
            ]
        }
    }
    
    private func toJSON(_ obj: [String: Any]) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [])
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
        case "12": return (39.0842, 117.2009)
        case "13": return (38.0428, 114.5149)
        case "14": return (37.8706, 112.5489)
        case "15": return (40.8183, 111.7656)
        case "21": return (41.8057, 123.4315)
        case "22": return (43.8868, 125.3245)
        case "23": return (45.8038, 126.5350)
        case "31": return (31.2304, 121.4737)
        case "32": return (32.0617, 118.7778)
        case "33": return (30.2741, 120.1551)
        case "34": return (31.8612, 117.2830)
        case "35": return (26.0745, 119.2965)
        case "36": return (28.6820, 115.8579)
        case "37": return (36.6683, 116.9972)
        case "41": return (34.7472, 113.6254)
        case "42": return (30.5928, 114.3055)
        case "43": return (28.2282, 112.9388)
        case "44": return (23.1291, 113.2644)
        case "45": return (22.8170, 108.3665)
        case "46": return (20.0174, 110.3492)
        case "50": return (29.5630, 106.5516)
        case "51": return (30.5728, 104.0668)
        case "52": return (26.6470, 106.6302)
        case "53": return (25.0389, 102.7183)
        case "54": return (29.6500, 91.1000)
        case "61": return (34.2658, 108.9541)
        case "62": return (36.0594, 103.8343)
        case "63": return (36.6171, 101.7782)
        case "64": return (38.4872, 106.2309)
        case "65": return (43.7930, 87.6271)
        case "71": return (25.0330, 121.5654)
        case "81": return (22.3193, 114.1694)
        case "82": return (22.1987, 113.5439)
        default: return (39.9042, 116.4074)
        }
    }
    
    private func getProvinceByAdcode(adcode: String) -> String {
        let prefix = String(adcode.prefix(2))
        
        switch prefix {
        case "11": return "北京市"
        case "12": return "天津市"
        case "13": return "河北省"
        case "14": return "山西省"
        case "15": return "内蒙古自治区"
        case "21": return "辽宁省"
        case "22": return "吉林省"
        case "23": return "黑龙江省"
        case "31": return "上海市"
        case "32": return "江苏省"
        case "33": return "浙江省"
        case "34": return "安徽省"
        case "35": return "福建省"
        case "36": return "江西省"
        case "37": return "山东省"
        case "41": return "河南省"
        case "42": return "湖北省"
        case "43": return "湖南省"
        case "44": return "广东省"
        case "45": return "广西壮族自治区"
        case "46": return "海南省"
        case "50": return "重庆市"
        case "51": return "四川省"
        case "52": return "贵州省"
        case "53": return "云南省"
        case "54": return "西藏自治区"
        case "61": return "陕西省"
        case "62": return "甘肃省"
        case "63": return "青海省"
        case "64": return "宁夏回族自治区"
        case "65": return "新疆维吾尔自治区"
        case "71": return "台湾省"
        case "81": return "香港特别行政区"
        case "82": return "澳门特别行政区"
        default: return "未知"
        }
    }
    
    private func getCityByAdcode(adcode: String) -> String {
        let prefix = String(adcode.prefix(2))
        
        switch prefix {
        case "11": return "北京市"
        case "12": return "天津市"
        case "31": return "上海市"
        case "50": return "重庆市"
        case "13": return "石家庄市"
        case "14": return "太原市"
        case "15": return "呼和浩特市"
        case "21": return "沈阳市"
        case "22": return "长春市"
        case "23": return "哈尔滨市"
        case "32": return "南京市"
        case "33": return "杭州市"
        case "34": return "合肥市"
        case "35": return "福州市"
        case "36": return "南昌市"
        case "37": return "济南市"
        case "41": return "郑州市"
        case "42": return "武汉市"
        case "43": return "长沙市"
        case "44": return "广州市"
        case "45": return "南宁市"
        case "46": return "海口市"
        case "51": return "成都市"
        case "52": return "贵阳市"
        case "53": return "昆明市"
        case "54": return "拉萨市"
        case "61": return "西安市"
        case "62": return "兰州市"
        case "63": return "西宁市"
        case "64": return "银川市"
        case "65": return "乌鲁木齐市"
        case "71": return "台北市"
        case "81": return "香港"
        case "82": return "澳门"
        default: return "城市"
        }
    }
    
    private func generateRequestId() -> String {
        let chars = "abcdef0123456789"
        return String((0..<16).map { _ in chars.randomElement()! })
    }
}
