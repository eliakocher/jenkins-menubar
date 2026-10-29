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

    @Test("LOG-02 a cut body is indented like a whole one, up to the cut")
    func cutBodyKeepsTheStart() {
        let whole = #"{"jobs":[{"name":"MR-1","result":"SUCCESS"},{"name":"MR-2","result":null}]}"#
        let indented = RequestRecord.indentedJSON(whole)
        for length in [10, 25, 40, 55, 70] {
            let cut = RequestRecord.indentedJSON(String(whole.prefix(length)))
            #expect(cut != nil && indented?.hasPrefix(cut ?? "?") == true, "cut at \(length)")
        }
        let record = RequestRecord(
            method: "GET", url: URL(string: "https://jenkins.example.com/api/json")!, status: 200, seconds: 1,
            responseBody: Data(whole.utf8), bodyLimit: 30)
        #expect(record.truncated && record.indentedBody == "{\n  \"jobs\": [\n    {\n      \"name\": \"MR-1\",\n      \"resul")
    }

    @Test("LOG-02 colors JSON by token")
    func colorsByToken() throws {
        let styled = try #require(JSONIndenter.indent(#"{"result":"SUCCESS","n":-1.5e3,"ok":true,"x":null,"s":"a\"é😀","l":[]}"#))
        let text = styled.text
        #expect(text == "{\n  \"result\": \"SUCCESS\",\n  \"n\": -1.5e3,\n  \"ok\": true,\n  \"x\": null,\n  \"s\": \"a\\\"é😀\",\n  \"l\": []\n}")

        // The spans in order, as the substrings of the text they cover (UTF-16, as an NSRange).
        let utf16 = Array(text.utf16)
        let covered = styled.spans.map { span in
            (span.kind, String(decoding: utf16[span.range], as: UTF16.self))
        }
        let expected: [(SyntaxKind, String)] = [
            (.jsonPunctuation, "{"),
            (.jsonKey, "\"result\""), (.jsonPunctuation, ":"), (.resultSuccess, "\"SUCCESS\""), (.jsonPunctuation, ","),
            (.jsonKey, "\"n\""), (.jsonPunctuation, ":"), (.jsonNumber, "-1.5e3"), (.jsonPunctuation, ","),
            (.jsonKey, "\"ok\""), (.jsonPunctuation, ":"), (.jsonKeyword, "true"), (.jsonPunctuation, ","),
            (.jsonKey, "\"x\""), (.jsonPunctuation, ":"), (.jsonKeyword, "null"), (.jsonPunctuation, ","),
            (.jsonKey, "\"s\""), (.jsonPunctuation, ":"), (.jsonString, "\"a\\\"é😀\""), (.jsonPunctuation, ","),
            (.jsonKey, "\"l\""), (.jsonPunctuation, ":"), (.jsonPunctuation, "["), (.jsonPunctuation, "]"),
            (.jsonPunctuation, "}"),
        ]
        #expect(covered.map(\.0) == expected.map(\.0))
        #expect(covered.map(\.1) == expected.map(\.1))
    }

    @Test(
        "LOG-02 the other results get their kind, and only as values",
        arguments: [("FAILURE", SyntaxKind.resultFailure), ("UNSTABLE", .resultUnstable), ("ABORTED", .resultAborted),
                    ("NOT_BUILT", .jsonString), ("success", .jsonString)])
    func resultKinds(value: String, kind: SyntaxKind) throws {
        let styled = try #require(JSONIndenter.indent(#"{"SUCCESS":"\#(value)"}"#))
        #expect(styled.spans.map(\.kind) == [.jsonPunctuation, .jsonKey, .jsonPunctuation, kind, .jsonPunctuation])
    }

    @Test("LOG-02 the details name the kinds of the request line, the headers and the body")
    func detailSpans() throws {
        let record = RequestRecord(
            method: "GET", url: URL(string: "https://jenkins.example.com/api/json")!, authorization: .basic, status: 200,
            seconds: 0.1, responseHeaders: ["X-Jenkins": "2.500"], responseBody: Data(#"{"result":"FAILURE"}"#.utf8))
        let details = RequestDetails(record: record)

        func covered(_ styled: StyledText) -> [String] {
            let utf16 = Array(styled.text.utf16)
            return styled.spans.map { "\($0.kind) \(String(decoding: utf16[$0.range], as: UTF16.self))" }
        }
        #expect(covered(details.styledRequest) == ["httpMethod GET", "headerName Authorization", "notKept (not kept)"])
        #expect(covered(details.styledHeaders) == ["headerName X-Jenkins"])
        #expect(covered(details.styledResponse) == [
            "jsonPunctuation {", "jsonKey \"result\"", "jsonPunctuation :", "resultFailure \"FAILURE\"", "jsonPunctuation }",
        ])
        #expect(details.responseText == "HTTP 200\n\n{\n  \"result\": \"FAILURE\"\n}")
    }
}
