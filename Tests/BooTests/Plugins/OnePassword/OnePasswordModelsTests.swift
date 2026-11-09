import XCTest

@testable import Boo

final class OnePasswordModelsTests: XCTestCase {
    func testParsesVaults() {
        let json = #"[{"id":"v1","name":"Private","content_version":3},{"name":"no id"}]"#
        XCTAssertEqual(OPParser.vaults(Data(json.utf8)), [OPVault(id: "v1", name: "Private")])
    }

    func testParsesItemsSortedByTitle() {
        let json = """
            [
              {"id":"b","title":"zeta","category":"LOGIN","vault":{"id":"v1","name":"Private"},
               "additional_information":"me@example.com"},
              {"id":"a","title":"Alpha","category":"API_CREDENTIAL","vault":{"id":"v2","name":"Work"}},
              {"title":"no id"}
            ]
            """
        let items = OPParser.items(Data(json.utf8))
        XCTAssertEqual(items.map(\.id), ["a", "b"])
        XCTAssertEqual(items[1].detail, "me@example.com")
        XCTAssertEqual(items[1].vaultName, "Private")
        XCTAssertTrue(items[1].isLogin)
        XCTAssertEqual(items[0].detail, "")
    }

    func testMalformedJSONYieldsNothing() {
        XCTAssertTrue(OPParser.items(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(OPParser.fields(Data("[]".utf8)).isEmpty)
    }

    private let login = """
        {"id":"i1","title":"GitHub","fields":[
          {"id":"username","type":"STRING","purpose":"USERNAME","label":"username","value":"octo",
           "reference":"op://Private/GitHub/username"},
          {"id":"password","type":"CONCEALED","purpose":"PASSWORD","label":"password","value":"s3cret",
           "reference":"op://Private/GitHub/password"},
          {"id":"totp","type":"OTP","label":"one-time password","value":"otpauth://x","totp":"123456",
           "reference":"op://Private/GitHub/one-time password?attribute=otp"}
        ]}
        """

    func testLoginSecrets() {
        let fields = OPParser.fields(Data(login.utf8))
        XCTAssertEqual(OPSecret.username.value(in: fields), "octo")
        XCTAssertEqual(OPSecret.password.value(in: fields), "s3cret")
        XCTAssertEqual(OPSecret.otp.value(in: fields), "123456")
        XCTAssertEqual(OPSecret.password.field(in: fields)?.reference, "op://Private/GitHub/password")
    }

    func testAPICredentialFallsBackToConcealedField() {
        let json = """
            {"fields":[
              {"id":"username","type":"STRING","label":"username","value":"bot"},
              {"id":"credential","type":"CONCEALED","label":"credential","value":"tok"}
            ]}
            """
        let fields = OPParser.fields(Data(json.utf8))
        XCTAssertEqual(OPSecret.username.value(in: fields), "bot")
        XCTAssertEqual(OPSecret.password.value(in: fields), "tok")
        XCTAssertNil(OPSecret.otp.value(in: fields))
    }

    func testEmptyValueCountsAsMissing() {
        let json = #"{"fields":[{"id":"password","type":"CONCEALED","purpose":"PASSWORD","label":"password"}]}"#
        XCTAssertNil(OPSecret.password.value(in: OPParser.fields(Data(json.utf8))))
    }

    func testErrorMessageStripsPrefix() {
        let stderr = "\n[ERROR] 2026/11/09 10:00:00 You are not currently signed in.\n"
        XCTAssertEqual(OPParser.errorMessage(stderr), "You are not currently signed in.")
        XCTAssertEqual(OPParser.errorMessage("plain failure\n"), "plain failure")
        XCTAssertEqual(OPParser.errorMessage(""), "")
    }

    func testParsesAccounts() {
        let json = """
            [{"url":"my.1password.com","email":"me@example.com","user_uuid":"U","account_uuid":"A1"},
             {"url":"team.1password.com","account_uuid":"A2"},{"email":"no id"}]
            """
        let accounts = OPParser.accounts(Data(json.utf8))
        XCTAssertEqual(accounts.map(\.id), ["A1", "A2"])
        XCTAssertEqual(accounts[0].title, "me@example.com · my.1password.com")
        XCTAssertEqual(accounts[1].title, "team.1password.com")
    }

    func testParsesFavoriteAndPrimaryURL() {
        let json = """
            [{"id":"a","title":"A","favorite":true,
              "urls":[{"href":"other.example.com"},{"primary":true,"href":"https://github.com/login"}]},
             {"id":"b","title":"B","urls":[{"href":""}]}]
            """
        let items = OPParser.items(Data(json.utf8))
        XCTAssertTrue(items[0].favorite)
        XCTAssertEqual(items[0].url, "https://github.com/login")
        XCTAssertFalse(items[1].favorite)
        XCTAssertNil(items[1].url)
    }

    func testWebURL() {
        func item(_ url: String?) -> OPItem {
            OPItem(id: "a", title: "A", category: "LOGIN", vaultID: "", vaultName: "", detail: "", url: url)
        }
        XCTAssertEqual(item("github.com").webURL?.absoluteString, "https://github.com")
        XCTAssertEqual(item("http://intranet/x").webURL?.absoluteString, "http://intranet/x")
        XCTAssertNil(item("ssh://host").webURL)
        XCTAssertNil(item(nil).webURL)
    }

    func testFieldSectionsAndVisibility() {
        let json = """
            {"fields":[
              {"id":"notes","type":"STRING","purpose":"NOTES","label":"notesPlain"},
              {"id":"key","type":"CONCEALED","label":"api key","section":{"id":"s","label":"API"},
               "reference":"op://V/I/API/api key"},
              {"id":"host","type":"STRING","label":"host","value":"db.local","section":{"id":"s2","label":""}}
            ]}
            """
        let fields = OPParser.fields(Data(json.utf8))
        XCTAssertFalse(fields[0].isShown, "empty plain field is hidden")
        XCTAssertTrue(fields[1].isShown, "concealed field shows even without a value")
        XCTAssertEqual(fields[1].section, "API")
        XCTAssertNil(fields[2].section, "empty section label counts as none")
        XCTAssertEqual(fields[2].secret, "db.local")
        XCTAssertFalse(fields[2].isConcealed)
    }

    func testOTPSecretIsCurrentCode() {
        let fields = OPParser.fields(Data(login.utf8))
        let otp = fields.first(where: \.isOTP)
        XCTAssertEqual(otp?.secret, "123456")
        XCTAssertTrue(otp?.isConcealed ?? false)
    }

    func testNeedsSignIn() {
        XCTAssertTrue(OPParser.needsSignIn("You are not currently signed in. Please run `op signin --help`"))
        XCTAssertTrue(OPParser.needsSignIn("No accounts configured for use with 1Password CLI."))
        XCTAssertFalse(OPParser.needsSignIn("\"x\" isn't an item in any vault."))
    }

    func testItemMatchesTitleDetailOrVault() {
        let item = OPItem(
            id: "a", title: "GitHub", category: "LOGIN", vaultID: "v", vaultName: "Work", detail: "octo")
        XCTAssertTrue(item.matches(""))
        XCTAssertTrue(item.matches("git"))
        XCTAssertTrue(item.matches("oct"))
        XCTAssertTrue(item.matches("work"))
        XCTAssertFalse(item.matches("gitlab"))
    }
}
