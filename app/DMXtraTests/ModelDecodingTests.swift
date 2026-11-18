import Foundation
import Testing
@testable import DMXtra

/// The JSON here is copied from embedded/API.md.
struct ModelDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func controllerInfo() throws {
        let info = try decode(ControllerInfo.self,
            #"{"name":"DMXtra","firmware":"0.2.0","universeSize":512,"maxFixtures":32,"fixtureCount":2}"#)
        #expect(info == ControllerInfo(name: "DMXtra", firmware: "0.2.0", universeSize: 512, maxFixtures: 32, fixtureCount: 2))
    }

    @Test func fixtureTypes() throws {
        let types = try decode([FixtureType].self, """
        [
          {"type":"dimmer","label":"Dimmer","channelCount":1,"channels":["intensity"]},
          {"type":"rgb","label":"RGB","channelCount":3,"channels":["red","green","blue"]},
          {"type":"rgbw","label":"RGBW","channelCount":4,"channels":["red","green","blue","white"]}
        ]
        """)
        #expect(types.map(\.type) == ["dimmer", "rgb", "rgbw"])
        #expect(types[2].label == "RGBW")
        #expect(types[2].channels == ["red", "green", "blue", "white"])
        #expect(types[0].id == "dimmer")
    }

    @Test func fixtures() throws {
        let fixtures = try decode([Fixture].self, """
        [
          {"id":1,"name":"Wash 1","type":"rgb","address":1,"channelCount":3,
           "channels":["red","green","blue"],"values":[255,0,128]},
          {"id":2,"name":"Wash 2","type":"rgb","address":4,"channelCount":3,
           "channels":["red","green","blue"],"values":[0,0,0]}
        ]
        """)
        #expect(fixtures.count == 2)
        #expect(fixtures[0].values == [255, 0, 128])
        #expect(fixtures[1].channelRange == 4...6)
        #expect(fixtures[1].addressLabel == "4–6")
        #expect(fixtures[0].isColorFixture)
    }

    @Test func unknownFixtureTypeStillDecodes() throws {
        let f = try decode(Fixture.self, """
        {"id":9,"name":"Mover","type":"movinghead","address":20,"channelCount":2,
         "channels":["pan","tilt"],"values":[10,20]}
        """)
        #expect(f.channels == ["pan", "tilt"])
        #expect(!f.isColorFixture)
        #expect(f.addressLabel == "20–21")
    }

    @Test func dmxRange() throws {
        let r = try decode(DmxRange.self, #"{"start":1,"values":[255,0,128,0,0,0]}"#)
        #expect(r == DmxRange(start: 1, values: [255, 0, 128, 0, 0, 0]))
        let w = try decode(DmxWriteResult.self, #"{"start":1,"count":3}"#)
        #expect(w == DmxWriteResult(start: 1, count: 3))
    }

    @Test func serverError() throws {
        let e = try decode(ServerErrorBody.self, #"{"error":"address overlaps another fixture"}"#)
        #expect(e.error == "address overlaps another fixture")
    }

    @Test func fixtureUpdateEncodesNullsAndOmitsMissingFields() throws {
        let data = try JSONEncoder().encode(FixtureUpdate(values: [255, nil, 0]))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj.keys.sorted() == ["values"])
        let values = try #require(obj["values"] as? [Any])
        #expect(values.count == 3)
        #expect(values[0] as? Int == 255)
        #expect(values[1] is NSNull)
        #expect(values[2] as? Int == 0)

        let rename = try JSONEncoder().encode(FixtureUpdate(name: "Stage Left", address: 10))
        let obj2 = try #require(JSONSerialization.jsonObject(with: rename) as? [String: Any])
        #expect(obj2.keys.sorted() == ["address", "name"])
    }

    @Test func newFixtureEncoding() throws {
        let data = try JSONEncoder().encode(NewFixture(name: "Wash 3", type: "rgb", address: 7))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["name"] as? String == "Wash 3")
        #expect(obj["type"] as? String == "rgb")
        #expect(obj["address"] as? Int == 7)
    }

    @Test(arguments: [
        ("10.103.210.50", "http://10.103.210.50"),
        ("127.0.0.1:8080", "http://127.0.0.1:8080"),
        ("  dmxtra.local  ", "http://dmxtra.local"),
        ("http://10.0.0.5:80/", "http://10.0.0.5:80"),
    ])
    func addressParsing(input: String, expected: String) {
        #expect(ControllerAddress.baseURL(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://host", "host/path", "has space", "host:99999"])
    func invalidAddresses(input: String) {
        #expect(ControllerAddress.baseURL(from: input) == nil)
    }
}
