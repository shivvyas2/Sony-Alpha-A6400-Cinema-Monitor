import XCTest
@testable import SonyCameraKit

final class CameraStateTests: XCTestCase {
    func testAppliesEventByType() throws {
        let json = """
        [
          {"type":"availableApiList","names":["getEvent","setShutterSpeed","actTakePicture"]},
          {"type":"cameraStatus","cameraStatus":"IDLE"},
          null,
          {"type":"liveviewStatus","liveviewStatus":true},
          null, null, null, null, null, null,
          [{"type":"storageInformation","storageInformation":[{"numberOfRecordableImages":812,"recordableTime":-1,"storageID":"Memory Card 1","storageDescription":"SD","recordTarget":true}]}],
          {"type":"exposureCompensation","currentExposureCompensation":2,"maxExposureCompensation":15,"minExposureCompensation":-15,"stepIndexOfExposureCompensation":1},
          {"type":"fNumber","currentFNumber":"2.8","fNumberCandidates":["1.8","2.0","2.2","2.5","2.8","3.2"]},
          {"type":"focusMode","currentFocusMode":"AF-C","focusModeCandidates":["AF-S","AF-C","MF"]},
          {"type":"isoSpeedRate","currentIsoSpeedRate":"800","isoSpeedRateCandidates":["100","200","400","800","1600"]},
          {"type":"shutterSpeed","currentShutterSpeed":"1/50","shutterSpeedCandidates":["1/30","1/50","1/60","1/100"]},
          {"type":"whiteBalance","currentWhiteBalanceMode":"Color Temperature","currentColorTemperature":5600,"checkAvailability":true},
          {"type":"batteryInfo","batteryInfo":[{"batteryID":"","status":"Active","additionalStatus":"","levelNumer":3,"levelDenom":4,"description":""}]},
          {"type":"recordingTime","recordingTime":73}
        ]
        """
        var s = CameraState()
        s.apply(event: try JSON.parse(Data(json.utf8)))
        XCTAssertTrue(s.supports("setShutterSpeed"))
        XCTAssertEqual(s.cameraStatus, "IDLE")
        XCTAssertTrue(s.liveviewStatus)
        XCTAssertEqual(s.shotsRemaining, 812)
        XCTAssertNil(s.recordableMinutes)
        XCTAssertEqual(s.exposureCompensation?.label, "+0.7")
        XCTAssertEqual(s.fNumber, "2.8")
        XCTAssertEqual(s.fNumberCandidates.count, 6)
        XCTAssertEqual(s.focusMode, "AF-C")
        XCTAssertEqual(s.iso, "800")
        XCTAssertEqual(s.shutterSpeed, "1/50")
        XCTAssertEqual(s.colorTemperature, 5600)
        XCTAssertEqual(s.battery?.fraction, 0.75)
        XCTAssertEqual(s.recordingTimeSeconds, 73)
    }

    func testPartialEventKeepsPreviousValues() throws {
        var s = CameraState()
        s.apply(event: try JSON.parse(Data(#"[{"type":"shutterSpeed","currentShutterSpeed":"1/50","shutterSpeedCandidates":["1/50"]}]"#.utf8)))
        s.apply(event: try JSON.parse(Data(#"[null,{"type":"cameraStatus","cameraStatus":"MovieRecording"}]"#.utf8)))
        XCTAssertEqual(s.shutterSpeed, "1/50")
        XCTAssertTrue(s.isRecording)
    }

    func testZeroAndOneStayNumbersAndBoolsStayBools() throws {
        let j = try JSON.parse(Data(#"{"zero":0,"one":1,"t":true,"f":false,"n":2.5}"#.utf8))
        XCTAssertEqual(j["zero"].int, 0)
        XCTAssertEqual(j["one"].int, 1)
        XCTAssertEqual(j["t"].bool, true)
        XCTAssertEqual(j["f"].bool, false)
        XCTAssertNil(j["zero"].string)
        XCTAssertEqual(j["n"].double, 2.5)
        XCTAssertEqual(j["t"], .bool(true))
        XCTAssertEqual(j["one"], .number(1))
    }

    func testRequestEncoding() throws {
        let data = try SonyCameraClient.encodeRequest(method: "setFNumber", params: ["2.8"], id: 3, version: "1.0")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["method"] as? String, "setFNumber")
        XCTAssertEqual(obj["params"] as? [String], ["2.8"])
        XCTAssertEqual(obj["id"] as? Int, 3)
        XCTAssertEqual(obj["version"] as? String, "1.0")
    }

    func testDeviceDescriptionParsing() throws {
        let xml = """
        <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:av="urn:schemas-sony-com:av">
        <device><friendlyName>ILCE-6400</friendlyName><modelName>ILCE-6400</modelName>
        <av:X_ScalarWebAPI_DeviceInfo><av:X_ScalarWebAPI_Version>1.0</av:X_ScalarWebAPI_Version>
        <av:X_ScalarWebAPI_ServiceList>
        <av:X_ScalarWebAPI_Service><av:X_ScalarWebAPI_ServiceType>guide</av:X_ScalarWebAPI_ServiceType><av:X_ScalarWebAPI_ActionList_URL>http://192.168.122.1:8080/sony</av:X_ScalarWebAPI_ActionList_URL></av:X_ScalarWebAPI_Service>
        <av:X_ScalarWebAPI_Service><av:X_ScalarWebAPI_ServiceType>camera</av:X_ScalarWebAPI_ServiceType><av:X_ScalarWebAPI_ActionList_URL>http://192.168.122.1:8080/sony</av:X_ScalarWebAPI_ActionList_URL></av:X_ScalarWebAPI_Service>
        </av:X_ScalarWebAPI_ServiceList></av:X_ScalarWebAPI_DeviceInfo></device></root>
        """
        let cam = try SSDPDiscovery.parseDescription(Data(xml.utf8), base: URL(string: "http://192.168.122.1:64321/dd.xml")!)
        XCTAssertEqual(cam.friendlyName, "ILCE-6400")
        XCTAssertEqual(cam.serviceURL.absoluteString, "http://192.168.122.1:8080/sony")
    }

    func testDecodesFormatAndZoomEvents() throws {
        let json = """
        [
          {"type":"stillSize","currentAspect":"3:2","currentSize":"L"},
          {"type":"movieQuality","currentMovieQuality":"PS","movieQualityCandidates":["PS","HQ","STD"]},
          {"type":"movieFileFormat","currentMovieFileFormat":"XAVC S","movieFileFormatCandidates":["MP4","XAVC S"]},
          {"type":"zoomInformation","zoomPosition":42,"zoomNumberBox":1,"zoomIndexCurrentBox":0,"zoomPositionCurrentBox":42}
        ]
        """
        var s = CameraState()
        s.apply(event: try JSON.parse(Data(json.utf8)))
        XCTAssertEqual(s.stillSize, StillSize(aspect: "3:2", size: "L"))
        XCTAssertEqual(s.movieQuality, "PS"); XCTAssertEqual(s.movieQualityCandidates, ["PS", "HQ", "STD"])
        XCTAssertEqual(s.movieFileFormat, "XAVC S"); XCTAssertEqual(s.movieFileFormatCandidates, ["MP4", "XAVC S"])
        XCTAssertEqual(s.zoomPosition, 42)
    }
}
