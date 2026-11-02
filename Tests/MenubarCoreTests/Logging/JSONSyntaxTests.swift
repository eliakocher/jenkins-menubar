import Foundation
import Testing

@testable import MenubarCore

@Suite("JSONSyntax")
struct JSONSyntaxTests {
    @Test(
        "LOG-02 indents a cut JSON body",
        arguments: [
            // a cut object, in a number, after a comma, after a colon
            (#"{"z":1,"a":[1,2"#, "{\n  \"z\": 1,\n  \"a\": [\n    1,\n    2"),
            (#"{"z":1,"a":12"#, "{\n  \"z\": 1,\n  \"a\": 12"),
            (#"{"z":1,"#, "{\n  \"z\": 1,"),
            (#"{"z":{"y":[]},"a":"#, "{\n  \"z\": {\n    \"y\": []\n  },\n  \"a\": "),
            // a cut string, with and without an escape at the cut, and a cut key
            (#"{"z":1,"b":"cut her"#, "{\n  \"z\": 1,\n  \"b\": \"cut her"),
            (#"{"b":"a\"#, "{\n  \"b\": \"a\\"),
            (#"{"b":1,"lastBu"#, "{\n  \"b\": 1,\n  \"lastBu"),
            // a cut keyword, and a bracket that was just opened
            (#"[true,fal"#, "[\n  true,\n  fal"),
            ("[", "["),
        ])
    func indentsCut(json: String, expected: String) {
        #expect(RequestRecord.indentedJSON(json) == expected)
    }

    @Test(
        "LOG-02 a text that isn't JSON stays plain",
        arguments: [
            "", "   ", "<html><body>Please log in</body></html>", "OK", "Error 500", "{'a': 1}", #"{"a" 1}"#, #"{"a":1}}"#,
            #"{"a":1} {"b":2}"#, "[1,2}", #"{"a":,}"#, "[1,]", "nulx", "truex",
        ])
    func plain(text: String) {
        #expect(RequestRecord.indentedJSON(text) == nil)
    }
}
