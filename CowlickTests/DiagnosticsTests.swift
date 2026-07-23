import XCTest

@testable import Cowlick

@MainActor
final class DiagnosticsTests: XCTestCase {
  func testLaunchAssetDiagnosticsRequiresBothTestingSignals() {
    XCTAssertEqual(
      DiagnosticsService.reportMode(
        arguments: [], environment: ["COWLICK_ASSET_CAPTURE": "1"]),
      .live)
    XCTAssertEqual(
      DiagnosticsService.reportMode(arguments: ["--ui-testing"], environment: [:]),
      .live)
    XCTAssertEqual(
      DiagnosticsService.reportMode(
        arguments: ["--ui-testing"], environment: ["COWLICK_ASSET_CAPTURE": "true"]),
      .live)
    XCTAssertEqual(
      DiagnosticsService.reportMode(
        arguments: ["--ui-testing"], environment: ["COWLICK_ASSET_CAPTURE": "1"]),
      .launchAssetDemo)
  }

  func testLaunchAssetDiagnosticsIsHealthyTruthfulAndMachineIndependent() {
    let report = DiagnosticsService.launchAssetDemoReport

    for required in [
      "Launch-asset demo snapshot — not live device data",
      "Hook status: Installed (demo)",
      "Codex hook trust: Trusted (demo)",
      "Helper installed: true",
      "Socket status: listening",
      "API-price equivalent: Local estimate is labeled and separate from billing",
      "Display layout: Generic non-notch demo capture",
    ] {
      XCTAssertTrue(report.contains(required), "Missing \(required) in:\n\(report)")
    }

    for forbidden in [
      "hooks are not installed",
      "hooks are missing or disabled",
      "Codex hook trust: Untrusted",
      "Codex hook trust: Needs review",
      "Codex hook trust: Unavailable",
      "Helper installed: false",
      "macOS: Version",
      "Architecture: arm64",
      "Display 1:",
      "/Users/",
    ] {
      XCTAssertFalse(report.localizedCaseInsensitiveContains(forbidden), report)
    }
  }

  func testSanitizesPathsAndSecrets() {
    let input = "failed /Users/example/private token=abc123 password:letmein"
    let output = EventLogger.sanitizeError(input)
    XCTAssertFalse(output.contains("example"))
    XCTAssertFalse(output.contains("abc123"))
    XCTAssertFalse(output.contains("letmein"))
    XCTAssertTrue(output.contains("token=<redacted>"))
  }

  func testSanitizesJSONKeysBearerCredentialsAndProjectControlCharacters() {
    let input =
      #"Authorization: Bearer sk-live-secret x-api-key="abc123" auth_token='def456'"#
    let output = EventLogger.sanitizeError(input)

    XCTAssertFalse(output.contains("sk-live-secret"))
    XCTAssertFalse(output.contains("abc123"))
    XCTAssertFalse(output.contains("def456"))
    XCTAssertFalse(EventLogger.sanitizeProject("Project\nInjected").contains("\n"))
  }

  func testControlsCannotSplitPathOrCredentialRecognizers() {
    let input =
      "failed /U\u{E000}s\u{001B}ers/ali\u{E000}ce/private Authori\u{E000}za\u{001B}tion: Be\u{E000}a\u{001B}rer sk-live-\u{E000}ta\u{001B}il OPEN\u{001B}AI_API_K\u{E000}EY=sk-key-\u{E000}ta\u{001B}il"
    let output = EventLogger.sanitizeError(input)

    XCTAssertFalse(output.localizedCaseInsensitiveContains("alice"))
    XCTAssertFalse(output.contains("sk-live"))
    XCTAssertFalse(output.contains("tail"))
    XCTAssertFalse(output.contains("sk-key"))
    XCTAssertFalse(output.contains("\u{E000}"))
    XCTAssertTrue(output.contains("~/private"), output)
    XCTAssertTrue(output.contains("authorization=<redacted>"))
    XCTAssertFalse(output.contains("OPENAI_API_KEY"))
    XCTAssertFalse(
      EventLogger.sanitizeProject("token=x\u{E000}sk\u{001B}-live").contains("sk-live"))
  }

  func testUnicodeSeparatorsAndFormatScalarsCannotSplitPathOrCredentialRecognizers() {
    let input =
      "failed /U\u{00A0}s\u{2003}ers/Ali\u{2060}\u{00A0}ce/private OPEN\u{2003}AI_API_K\u{00A0}E\u{2060}Y=sk-key-\u{2003}ta\u{2060}il Authorization: Be\u{00A0}ar\u{2060}er sk-live-\u{2003}se\u{2060}cret"
    let output = EventLogger.sanitizeError(input)

    XCTAssertFalse(output.localizedCaseInsensitiveContains("alice"))
    XCTAssertFalse(output.contains("sk-key"))
    XCTAssertFalse(output.contains("tail"))
    XCTAssertFalse(output.contains("sk-live"))
    XCTAssertFalse(output.contains("secret"))
    XCTAssertTrue(output.contains("~/private"), output)
    XCTAssertTrue(output.contains("OPENAI_API_KEY=<redacted>"))
    XCTAssertTrue(output.contains("authorization=<redacted>"))
    XCTAssertFalse(
      EventLogger.sanitizeProject("token=x\u{00A0}sk\u{2003}-live").contains("sk-live"))
  }

  func testDefaultIgnorablesCannotSplitPathsCredentialsOrBearer() {
    let input =
      "failed /U\u{FE0F}s\u{034F}ers/Alice/private t\u{FE0F}ok\u{034F}en=token-secret api\u{FE0F}_\u{034F}key=api-secret Be\u{FE0F}ar\u{034F}er bearer-secret"
    let output = EventLogger.sanitizeError(input)

    XCTAssertFalse(output.localizedCaseInsensitiveContains("alice"))
    XCTAssertFalse(output.contains("token-secret"))
    XCTAssertFalse(output.contains("api-secret"))
    XCTAssertFalse(output.contains("bearer-secret"))
    XCTAssertTrue(output.contains("~/private"), output)
    XCTAssertTrue(output.contains("token=<redacted>"))
    XCTAssertTrue(output.contains("api_key=<redacted>"))
    XCTAssertTrue(output.contains("bearer=<redacted>"))
  }

  func testRemovedBearerValueBoundariesAreRestoredNarrowly() {
    for separator in ["\n", "\t", "\u{00A0}", "\u{2003}", "\u{2060}"] {
      XCTAssertEqual(
        EventLogger.sanitizeError("Bearer\(separator)sk-live-secret"),
        "bearer=<redacted>"
      )
    }
    for (removed, visible) in [
      ("Be-arer\nsk-hyphen-secret", "Be-arer sk-hyphen-secret"),
      ("bea.rer\u{2060}sk-dot-secret", "bea.rer sk-dot-secret"),
      ("bea_rer\nsk-underscore-secret", "bea_rer sk-underscore-secret"),
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(removed), "bearer=<redacted>")
      XCTAssertEqual(EventLogger.sanitizeError(visible), "bearer=<redacted>")
    }
    XCTAssertEqual(
      EventLogger.sanitizeError("“Be-arer”\n“sk-wrapped-normalized”"),
      "bearer=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("\"Bearer\"\nsk-quoted-secret"),
      "bearer=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("“Bearer”\u{00A0}“sk-smart-secret”"),
      "bearer=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("「Bearer」\u{2060}「sk-cjk-secret」"),
      "bearer=<redacted>"
    )

    XCTAssertEqual(EventLogger.sanitizeError("NotBearer\nvisible"), "NotBearervisible")
    XCTAssertEqual(EventLogger.sanitizeError("Not-Be-arer\nvisible"), "Not-Be-arervisible")
    XCTAssertEqual(
      EventLogger.sanitizeError("Not“Be-arer”\nvisible"),
      "Not“Be-arer”visible"
    )
    XCTAssertEqual(EventLogger.sanitizeError("BearerSuffix\u{2060}visible"), "BearerSuffixvisible")
    XCTAssertEqual(EventLogger.sanitizeError("Bearer\n, public"), "Bearer, public")
    XCTAssertEqual(EventLogger.sanitizeError("Bearer\t; public"), "Bearer; public")

    XCTAssertEqual(
      EventLogger.sanitizeError(
        "OPEN\nAI_API_KEY=sk-\u{2060}secret /U\u{00A0}sers/alice/private"
      ),
      "OPENAI_API_KEY=<redacted> ~/private"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("public=sk-\u{2060}secret"),
      "public=sk-secret"
    )

    let customHome = URL(fileURLWithPath: "/Users/alice")
    XCTAssertEqual(
      EventLogger.sanitizeError(
        "/Users/alice\nprivate; Bearer\nsk-home-after", homeDirectory: customHome),
      "~ private; bearer=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError(
        "😀 Bearer\nsk-home-before; /Users/alice\tprivate", homeDirectory: customHome),
      "😀 bearer=<redacted>; ~ private"
    )
  }

  func testRemovedBearerBoundariesRejectPathAndProseContexts() {
    for (input, expected) in [
      ("/tmp/Bearer\u{2060}Token/file", "/tmp/BearerToken/file"),
      ("C:\\Bearer\u{2060}Token\\file", "C:\\BearerToken\\file"),
      ("/tmp/“Bearer”\u{2060}Token/file", "/tmp/“Bearer”Token/file"),
      ("C:\\\"Bearer\"\nToken\\file", "C:\\\"Bearer\"Token\\file"),
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), expected)
    }

    for (input, expected) in [
      ("Bearer\n) public", "Bearer) public"),
      ("Bearer\n— public", "Bearer— public"),
      ("Bearer\n， public", "Bearer， public"),
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), expected)
    }

    for starter in ["+", "/", "~", ".", "_", "-"] {
      XCTAssertEqual(
        EventLogger.sanitizeError("Bearer\n\(starter)token; public"),
        "bearer=<redacted>; public"
      )
      XCTAssertEqual(
        EventLogger.sanitizeError("Bearer \(starter)token; public"),
        "bearer=<redacted>; public"
      )
    }
    XCTAssertEqual(
      EventLogger.sanitizeError("status:Bearer\nsecret; public"),
      "status:bearer=<redacted>; public"
    )
    XCTAssertEqual(EventLogger.sanitizeError("Bearer\n, public"), "Bearer, public")
  }

  func testRemovedBearerBoundaryRestorationIsLinearAndContextAware() {
    for separator in ["\n", "\u{2060}", "\u{E000}"] {
      XCTAssertEqual(
        EventLogger.sanitizeError("note\(separator)Bearer\(separator)MASKME; public"),
        "note bearer=<redacted>; public"
      )
      XCTAssertEqual(
        EventLogger.sanitizeError("note\(separator)Be\(separator)ar-er\(separator)MASKME"),
        "note bearer=<redacted>"
      )
    }
    XCTAssertEqual(
      EventLogger.sanitizeError("😀\u{2060}“Be-arer”\u{E000}“MASKME”"),
      "😀 bearer=<redacted>"
    )
    for input in [
      "note\u{2060}\\\"Bearer\\\"\u{2060}MASKME",
      "note\u{2060}“Bearer”\u{2060}MASKME",
      "note\u{2060}「Bearer」\u{2060}MASKME",
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.contains("<redacted>"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
    }

    for (input, expected) in [
      ("éBearer\u{2060}MASKME", "éBearerMASKME"),
      ("/tmp/@Bearer\u{2060}MASKME", "/tmp/@BearerMASKME"),
      ("/tmp/@\nBearer\u{2060}MASKME", "/tmp/@BearerMASKME"),
      ("C:\\temp\\@Bearer\u{2060}MASKME", "C:\\temp\\@BearerMASKME"),
      ("C:\\temp\\@\n\"Bearer\"\u{2060}MASKME", "C:\\temp\\@\"Bearer\"MASKME"),
      ("/tmp/@\n\\\"Bearer\\\"\u{2060}MASKME", "/tmp/@\\\"Bearer\\\"MASKME"),
      ("/tmp/@\n「Bearer」\u{2060}MASKME", "/tmp/@「Bearer」MASKME"),
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), expected)
    }

    func adversarialInput(scalarCount: Int) -> String {
      var scalars = Array("Bearer\nMASKME;".unicodeScalars)
      while scalars.count + 3 <= scalarCount {
        scalars.append("\u{2060}")
        scalars.append("\u{E000}")
        scalars.append("a")
      }
      while scalars.count < scalarCount { scalars.append("\u{2060}") }
      return String(String.UnicodeScalarView(scalars))
    }

    for scalarCount in [4_096, 8_191] {
      let output = EventLogger.sanitizeError(adversarialInput(scalarCount: scalarCount))
      XCTAssertTrue(output.hasPrefix("bearer=<redacted>;"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
    }
  }

  func testRedactsPrefixedSuffixedAndCommonCredentialIdentifiers() {
    let secrets = [
      "openai-secret", "access-secret", "refresh-secret", "client-secret", "anthropic-secret",
      "suffix-secret", "provider-secret",
    ]
    let input = """
      OPENAI_API_KEY=openai-secret,
      access_token=access-secret;
      refresh_token: refresh-secret;
      client_secret='client-secret';
      ANTHROPIC-API-KEY="anthropic-secret";
      api_key_openai=suffix-secret;
      provider_auth_token_prod=provider-secret
      """
    let output = EventLogger.sanitizeError(input)

    for secret in secrets {
      XCTAssertFalse(output.contains(secret), "\(secret): \(output)")
    }
    XCTAssertEqual(output.components(separatedBy: "<redacted>").count - 1, secrets.count)
  }

  func testRedactsCredentialAndSignatureIdentifiersWithoutMatchingProse() {
    for input in [
      "credential=MASKME; signature:MASKMORE",
      "X-Amz-Credential=MASKME&X-Amz-Signature=MASKMORE",
      #""X-Amz-Credential":"MASKME"; "X-Amz-Signature":"MASKMORE""#,
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.contains("<redacted>"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
      XCTAssertFalse(output.contains("MASKMORE"), output)
    }

    for prose in [
      "credential names only",
      "signature verification passed",
      "signed.headers=public",
      "designation=public",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(prose), prose)
    }
  }

  func testRedactsDottedSpacedAndMultiwordCredentialLabels() {
    let input =
      #"api.key=sk.live.secret; "api.key":"quoted.api.value"; "access.token":"access.value.tail"; client.secret='client.value.tail'; API key: spaced.value.tail; AWS secret access key: multi.value.tail"#
    let output = EventLogger.sanitizeError(input)

    for secret in [
      "sk.live.secret", "quoted.api.value", "access.value.tail", "client.value.tail",
      "spaced.value.tail", "multi.value.tail",
    ] {
      XCTAssertFalse(output.contains(secret), output)
    }
    XCTAssertTrue(output.contains("api.key=<redacted>"))
    XCTAssertTrue(output.contains("access.token=<redacted>"))
    XCTAssertTrue(output.contains("client.secret=<redacted>"))
    XCTAssertTrue(output.contains("API key=<redacted>"))
    XCTAssertTrue(output.contains("AWS secret access key=<redacted>"), output)
    XCTAssertEqual(EventLogger.sanitizeError(#""API key":"secret""#), "API key=<redacted>")
    XCTAssertEqual(
      EventLogger.sanitizeError(#""AWS secret access key":"secret""#),
      "AWS secret access key=<redacted>"
    )
  }

  func testLeavesBareKeyProseAndNonsensitiveDottedLabelsUntouched() {
    let input =
      #"key: visible release.version=1.2.3 "display.name":"public.value" API key names only"#

    XCTAssertEqual(EventLogger.sanitizeError(input), input)

    for prose in [
      #""API key names only"#,
      #""AWS secret access key" names only"#,
      #""API key" "public.value""#,
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(prose), prose)
    }

    let longFragment = String(repeating: "a”", count: 2_048)
    let bounded = EventLogger.sanitizeError(longFragment)
    XCTAssertFalse(bounded.contains("<redacted>"), bounded)
    XCTAssertEqual(bounded.unicodeScalars.count, 400)
  }

  func testMalformedCredentialLabelQuotesOnlyTerminateBeforeDelimiters() {
    for input in [
      #""API key' = double.single"#,
      #"'API key" : single.double"#,
      #"API key' = stray.single"#,
      #"API key" : stray.double"#,
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "API key=<redacted>")
    }

    for input in [#""API key'x=MASKME"#, #"'API key"x=MASKME"#] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.contains("<redacted>"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
    }

    for prose in [
      #""API key' names only"#,
      #"'API key" names only"#,
      #"API key' names only"#,
      #"API key" names only"#,
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(prose), prose)
    }
  }

  func testUnicodeCredentialLabelQuotesOnlyTerminateBeforeDelimiters() {
    XCTAssertEqual(EventLogger.sanitizeError("“API key”:smart.double"), "API key=<redacted>")
    XCTAssertEqual(
      EventLogger.sanitizeError("‘AWS secret access key’:smart.single"),
      "AWS secret access key=<redacted>"
    )
    XCTAssertEqual(EventLogger.sanitizeError("«API key»:guillemet.double"), "API key=<redacted>")
    XCTAssertEqual(
      EventLogger.sanitizeError("‹AWS secret access key›=guillemet.single"),
      "AWS secret access key=<redacted>"
    )
    XCTAssertEqual(EventLogger.sanitizeError("「API key」：cjk.secret"), "API key=<redacted>")

    for input in [
      "“API key”x=MASKME",
      "‘AWS secret access key’x=MASKME",
      "«API key»x=MASKME",
      "‹AWS secret access key›x=MASKME",
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.contains("<redacted>"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
    }

    for prose in [
      "“API key” names only",
      "‘AWS secret access key’ names only",
      "«API key» names only",
      "‹AWS secret access key› names only",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(prose), prose)
    }
  }

  func testRepeatedAndEscapedCredentialLabelTerminatorsRequireDelimiters() {
    for (input, expected) in [
      ("\"token\"\"=sk-ascii", "token=<redacted>"),
      ("token\"\"=sk-unwrapped", "token=<redacted>"),
      ("“token””＝sk-smart", "token=<redacted>"),
      ("「API key」」：sk-cjk", "API key=<redacted>"),
      ("token“”=sk-mixed", "token=<redacted>"),
      ("\"token\"”\\\"=sk-repeated-mixed", "token=<redacted>"),
      ("token” ” \\\" =sk-spaced-mixed", "token=<redacted>"),
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), expected)
    }

    let longQuoteRun = "token" + String(repeating: "\"", count: 1_024) + "=sk-long"
    XCTAssertEqual(EventLogger.sanitizeError(longQuoteRun), "token=<redacted>")

    for input in [
      "\"Bearer\"\"\nsk-bare-ascii",
      "“Bearer””\nsk-bare-smart",
      "\"Bearer\"”\\\"\nsk-bare-mixed",
      "“Bearer” ”\nsk-bare-spaced",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "bearer=<redacted>")
    }

    for (input, secret) in [
      (#"payload={\"api.key\":\"sk-api-secret\"}"#, "sk-api-secret"),
      (#"{\"token\":\"sk-token-secret\"}"#, "sk-token-secret"),
      (#"\"API key\" : sk-spaced-secret"#, "sk-spaced-secret"),
      (#"\"API key\"x=MASKME"#, "MASKME"),
      (#"payload={\"api.key\"x:\"MASKME\"}"#, "MASKME"),
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.contains("<redacted>"), output)
      XCTAssertFalse(output.contains(secret), output)
    }

    for prose in [
      "token\"\" prose",
      "token\\\" prose",
      #"\"API key\" prose"#,
      "“token”” prose",
      "token” ” prose",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(prose), prose)
    }
  }

  func testEmbeddedAndFragmentedCredentialLabelQuotesCannotBypassRedaction() {
    for input in [
      #"to"ken=MASKME"#,
      #"to\"ken=MASKME"#,
      "pass'word:MASKME",
      "api.”key=MASKME",
      "API “key”：MASKME",
      "to「ken」=MASKME",
      #"token"x=MASKME"#,
      #"token\"x=MASKME"#,
      "signature”part=MASKME",
      "credential「part」:MASKME",
      #"token" x=MASKME"#,
      #"token\" x=MASKME"#,
      #"token" "x=MASKME"#,
      "to” ken=MASKME",
      "to「 ken」=MASKME",
      "token\"⁠ x=MASKME",
      "to”⁠ ken=MASKME",
      #""token"x=MASKME"#,
      #""API key"x=MASKME"#,
      #"API key'x=MASKME"#,
      #"to" ken"x=MASKME"#,
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.contains("<redacted>"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
    }

    for input in [
      "autho”rization: Bearer MASKME, public",
      "Authorization “header”: Digest token=MASKME, response=MASKMORE",
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertEqual(output, "authorization=<redacted>")
      XCTAssertFalse(output.contains("MASKME"), output)
      XCTAssertFalse(output.contains("MASKMORE"), output)
    }

    for prose in [
      #"to"ken names only"#,
      #"to\"ken names only"#,
      "pass'word prose",
      "api.”key names only",
      "API “key” names only",
      "autho”rization prose",
      "version “name”：public",
      #"token"x names only"#,
      #"token\"x names only"#,
      "signature”part names only",
      "credential「part」 names only",
      #"token" x names only"#,
      #"token\" x names only"#,
      #"token" "x names only"#,
      "to” ken names only",
      "to「 ken」 names only",
      "token\"⁠ x names only",
      "to”⁠ ken names only",
    ] {
      XCTAssertEqual(
        EventLogger.sanitizeError(prose),
        prose.replacingOccurrences(of: "\u{2060}", with: "")
      )
    }
  }

  func testCredentialLabelWordBoundCoversLongestSensitiveIdentifier() {
    for input in [
      "s i g n a t u r e=MASKME",
      "c r e d e n t i a l:MASKME",
      "a u t h o r i z a t i o n=MASKME",
      "“a u t h o r i z a t i o n” x=MASKME",
      "s i g n a t u r e suffix=MASKME",
      "c r e d e n t i a l suffix=MASKME",
      "a u t h o r i z a t i o n " + String(repeating: "x ", count: 64) + "=MASKME",
      "token authorizationSuffixLong: Digest username=MASKME response=MASKMORE",
      "token bearerSuffixLong: MASKME response=MASKMORE",
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.contains("<redacted>"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
      XCTAssertFalse(output.contains("MASKMORE"), output)
    }

    for prose in [
      "s i g n a t u r e names only",
      "c r e d e n t i a l names only",
      "a u t h o r i z a t i o n names only",
      "“a u t h o r i z a t i o n” x names only",
      "s i g n a t u r e suffix names only",
      "c r e d e n t i a l suffix names only",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(prose), prose)
    }

    let adversarial =
      "a u t h o r i z a t i o n " + String(repeating: "x ", count: 1_480) + "=MASKME"
    measure(metrics: [XCTClockMetric()]) {
      let output = EventLogger.sanitizeError(adversarial)
      XCTAssertEqual(output, "authorization=<redacted>")
      XCTAssertFalse(output.contains("MASKME"), output)
    }
  }

  func testCredentialLabelTailWithoutDelimiterRemainsBoundedProse() {
    let prose =
      "a u t h o r i z a t i o n " + String(repeating: "x ", count: 1_480) + "names only"
    measure(metrics: [XCTClockMetric()]) {
      let output = EventLogger.sanitizeError(prose)
      XCTAssertEqual(output.unicodeScalars.count, 400)
      XCTAssertFalse(output.contains("<redacted>"), output)
    }
  }

  func testFullwidthCredentialDelimitersRemainBoundedToSensitiveLabels() {
    for (input, expected) in [
      ("token：direct.secret", "token=<redacted>"),
      ("api.key＝dotted.secret", "api.key=<redacted>"),
      (#""token"：quoted.secret"#, "token=<redacted>"),
      (#"'api.key'＝quoted.dotted"#, "api.key=<redacted>"),
      ("API key：spaced.secret", "API key=<redacted>"),
      (#""AWS secret access key"＝compound.secret"#, "AWS secret access key=<redacted>"),
      ("Bearer：auth.value", "Bearer=<redacted>"),
      ("Authorization＝Bearer auth.value", "authorization=<redacted>"),
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), expected)
    }

    for prose in [
      "key＝visible",
      "release.version：1.2.3",
      #""display.name"：public.value"#,
      "token；visible",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(prose), prose)
    }
  }

  func testQuotedCredentialValuesHonorEscapesAndUnmatchedQuotedKeysFallBack() {
    XCTAssertEqual(EventLogger.sanitizeError(#"token="abc\"def""#), "token=<redacted>")
    XCTAssertEqual(EventLogger.sanitizeError(#""token=secret"#), "token=<redacted>")
  }

  func testUnicodeCredentialValueWrappersFailClosedWithoutChangingUnquotedTermination() {
    for input in [
      "token=“curly secret value” visible",
      "token=‘curly secret value’ visible",
      "token=«guillemet secret value» visible",
      "token=‹guillemet secret value› visible",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "token=<redacted> visible")
    }

    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=“curly secret value” visible"),
      "api.key=<redacted> visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=«guillemet secret value»; visible"),
      "api.key=<redacted>; visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("token=“first»secret tail” visible"),
      "token=<redacted> visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=«first’secret tail» visible"),
      "api.key=<redacted> visible"
    )
    XCTAssertEqual(EventLogger.sanitizeError("token=“secret value trailing"), "token=<redacted>")
    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=«secret value trailing"),
      "api.key=<redacted>"
    )
    XCTAssertEqual(EventLogger.sanitizeError("token=“first»secret tail"), "token=<redacted>")
    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=«first”secret tail"),
      "api.key=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError(#"token="abc\"def" visible"#),
      "token=<redacted> visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("token=secret visible"),
      "token=<redacted> visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=secret; visible"),
      "api.key=<redacted>; visible"
    )
  }

  func testExactCredentialValueWrappersRequireBoundaryAfterClose() {
    for (input, expected) in [
      (#"token="alpha"beta visible"#, "token=<redacted>"),
      (#"token="alpha".beta visible"#, "token=<redacted>"),
      ("api.key=“alpha”beta visible", "api.key=<redacted>"),
      ("api.key=“alpha”-beta visible", "api.key=<redacted>"),
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), expected)
    }

    XCTAssertEqual(
      EventLogger.sanitizeError(#"token="alpha" visible"#),
      "token=<redacted> visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError(#"token="alpha", visible"#),
      "token=<redacted>, visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=“alpha” visible"),
      "api.key=<redacted> visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=“alpha”; visible"),
      "api.key=<redacted>; visible"
    )
  }

  func testWrongOrUnsupportedUnicodeValueQuotesFailClosed() {
    for (input, expected) in [
      ("token=”alpha beta” visible", "token=<redacted>"),
      ("token=’alpha,beta’ visible", "token=<redacted>"),
      ("api.key=»alpha;beta» visible", "api.key=<redacted>"),
      ("token=⸂alpha beta⸃ visible", "token=<redacted>"),
      ("api.key=⸃alpha; beta⸃ visible", "api.key=<redacted>"),
      (#"token=prefix"alpha beta"#, "token=<redacted>"),
      ("api.key=prefix'alpha,beta visible", "api.key=<redacted>"),
      ("token=prefix”alpha beta", "token=<redacted>"),
      ("api.key=prefix“alpha beta” visible", "api.key=<redacted>"),
      ("token=「alpha beta」 visible", "token=<redacted>"),
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), expected)
    }

    for input in [
      "Bearer ”alpha; beta” visible",
      "Bearer ⸂alpha, beta⸃ visible",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "bearer=<redacted>")
    }
    for input in [
      "Authorization: Bearer »alpha, beta» visible",
      "Authorization: Bearer ⸃alpha; beta⸃ visible",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "authorization=<redacted>")
    }

    XCTAssertEqual(
      EventLogger.sanitizeError("token=(public) visible"),
      "token=<redacted> visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("api.key=—public visible"),
      "api.key=<redacted> visible"
    )
  }

  func testBearerDelimiterFormsAndProtectedContinuationsFailClosed() {
    XCTAssertEqual(
      EventLogger.sanitizeError("bearer=first; Bearer: second"),
      "bearer=<redacted>; Bearer=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Bearer = third; Bearer : fourth"),
      "Bearer=<redacted>; Bearer=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Authorization: Bearer sk-live-\n tail"),
      "authorization=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError(#"Bearer "sk-live" tail; visible"#),
      "bearer=<redacted>; visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Authorization: Bearer auth.value api.key: field.value"),
      "authorization=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Authorization: Bearer auth.value API key: field.value"),
      "authorization=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Bearer auth.value api.key: field.value"),
      "bearer=<redacted> api.key=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Bearer auth.value API key: field.value"),
      "bearer=<redacted> API key=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Bearer auth.value api.key：field.value"),
      "bearer=<redacted> api.key=<redacted>"
    )

    for prose in ["Bearer", #""Bearer""#, "Bearer, visible prose", "A Bearer, by definition"] {
      XCTAssertEqual(EventLogger.sanitizeError(prose), prose)
    }
  }

  #if DEBUG
    func testBearerProtectedValueFieldScanningRemainsLinearForRepeatedCandidates() {
      let input = "Bearer: value " + String(repeating: "token ", count: 500) + "visible"
      EventLogger.resetCredentialLabelScanCountForTesting()

      XCTAssertEqual(EventLogger.sanitizeError(input), "Bearer=<redacted>")
      XCTAssertEqual(EventLogger.credentialLabelScanCountForTesting, 2)
    }
  #endif

  func testStructuredAuthorizationValuesRemainOpaqueAcrossDelimiters() {
    let aws = EventLogger.sanitizeError(
      "Authorization: AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/20260719/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=deadbeef"
    )
    XCTAssertEqual(aws, "authorization=<redacted>")
    for secret in ["AKIAEXAMPLE", "Credential", "SignedHeaders", "Signature", "deadbeef"] {
      XCTAssertFalse(aws.contains(secret), aws)
    }

    for input in [
      "Authorization: Digest username=Mufasa, realm=testrealm@host.com, nonce=abc123, uri=/dir/index.html, response=feedface",
      #"Authorization: Digest username="Mufasa", realm="testrealm", nonce="abc123", response="feedface""#,
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertEqual(output, "authorization=<redacted>")
      for secret in ["Mufasa", "nonce", "abc123", "response", "feedface"] {
        XCTAssertFalse(output.contains(secret), output)
      }
    }

    XCTAssertEqual(
      EventLogger.sanitizeError(
        "Authorization: AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/request, SignedHeaders=host;x-amz-date, Signature=deadbeef api.key: following-secret"
      ),
      "authorization=<redacted>"
    )
    for input in [
      "Authorization: Digest token=abc123, response=feedface",
      "Authorization: AWS4-HMAC-SHA256 Credential=AKIAEXAMPLE/request, SignedHeaders=host;x-amz-date, Signature=deadbeef token=abc123, response=feedface",
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertEqual(output, "authorization=<redacted>")
      for secret in ["abc123", "feedface", "response", "Signature", "deadbeef"] {
        XCTAssertFalse(output.contains(secret), output)
      }
    }
    XCTAssertEqual(
      EventLogger.sanitizeError("Bearer bearer.secret; public, text"),
      "bearer=<redacted>; public, text"
    )
  }

  func testCompoundProtectedLabelsPreferAuthorizationAndBearerSemantics() {
    for input in [
      "Authorization token: Bearer MASKME; public",
      #""Authorization token": Digest token=MASKME, response=MASKMORE"#,
      "HTTP Authorization token: AWS4 Credential=MASKME, Signature=MASKMORE",
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.hasSuffix("authorization=<redacted>"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
      XCTAssertFalse(output.contains("MASKMORE"), output)
    }

    for input in [
      "Bearer token: MASKME; public",
      #""Bearer token"=MASKME, public"#,
    ] {
      let output = EventLogger.sanitizeError(input)
      XCTAssertTrue(output.contains("<redacted>"), output)
      XCTAssertFalse(output.contains("MASKME"), output)
    }
  }

  func testProtectedValuesHonorPairedUnicodeWrappersAndFailClosed() {
    XCTAssertEqual(
      EventLogger.sanitizeError("Bearer “first;secret tail” visible"),
      "bearer=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Authorization: Bearer «first,secret tail» visible"),
      "authorization=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Bearer “first api.key: inner.secret; tail” API key: field.value"),
      "bearer=<redacted> API key=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError(
        "Authorization: Bearer «first API key: inner.secret, tail» api.key: field.value"
      ),
      "authorization=<redacted>"
    )

    for input in [
      "Bearer “first;secret tail",
      "Bearer “first»secret; tail",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "bearer=<redacted>")
    }
    for input in [
      "Authorization: Bearer «first,secret tail",
      "Authorization: Bearer «first”secret, tail",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "authorization=<redacted>")
    }
  }

  func testProtectedMidTokenQuotesFailClosedButBoundaryWrappersClose() {
    for input in [
      #"Bearer prefix"safe";secret.tail"#,
      "Bearer prefix“safe”;secret.tail",
      #"Bearer prefix"safe;secret.tail"#,
      "Bearer prefix“safe;secret.tail",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "bearer=<redacted>")
    }
    for input in [
      #"Authorization: Bearer prefix"safe",secret.tail"#,
      "Authorization: Bearer prefix“safe”,secret.tail",
      #"Authorization: Bearer prefix"safe,secret.tail"#,
      "Authorization: Bearer prefix“safe,secret.tail",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "authorization=<redacted>")
    }
    for input in [
      #"Bearer "safe"suffix;secret.tail"#,
      "Bearer “safe”suffix;secret.tail",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "bearer=<redacted>")
    }
    for input in [
      #"Authorization: Bearer "safe"suffix,secret.tail"#,
      "Authorization: Bearer “safe”suffix,secret.tail",
    ] {
      XCTAssertEqual(EventLogger.sanitizeError(input), "authorization=<redacted>")
    }

    XCTAssertEqual(
      EventLogger.sanitizeError(#"Bearer "safe;value"; visible"#),
      "bearer=<redacted>; visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Bearer “safe;value”; visible"),
      "bearer=<redacted>; visible"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError(#"Authorization: Bearer prefix "safe,value", visible"#),
      "authorization=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Authorization: Bearer prefix “safe,value”, visible"),
      "authorization=<redacted>"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError(#"Bearer "safe" visible; public"#),
      "bearer=<redacted>; public"
    )
    XCTAssertEqual(
      EventLogger.sanitizeError("Authorization: Bearer “safe” visible, public"),
      "authorization=<redacted>"
    )
  }

  func testRedactsExactStandardizedCustomHomeBeforeUsersFallback() {
    let customHome = URL(fileURLWithPath: "/Network/Homes/teams/../alice").standardizedFileURL
    let input =
      "custom /net\u{001B}work/hOMes/ali\u{E000}ce/private fallback /uSe\u{E000}Rs/Bob/project boundary /UsersBackup/kept"
    let output = EventLogger.sanitizeError(input, homeDirectory: customHome)

    XCTAssertFalse(output.localizedCaseInsensitiveContains("alice"))
    XCTAssertFalse(output.localizedCaseInsensitiveContains("bob"))
    XCTAssertTrue(output.contains("custom ~/private"))
    XCTAssertTrue(output.contains("fallback ~/project"))
    XCTAssertTrue(output.contains("/UsersBackup/kept"))
  }

  func testCustomHomeRedactionPreservesPunctuationAndRemovedSeparatorBoundaries() {
    let customHome = URL(fileURLWithPath: "/Network/Homes/alice")
    let input =
      "colon \(customHome.path): permission comma \(customHome.path), close (\(customHome.path)) nbsp \(customHome.path)\u{00A0}private em \(customHome.path)\u{2003}private newline \(customHome.path)\nprivate tab \(customHome.path)\tprivate nul \(customHome.path)\u{0000}private private-use \(customHome.path)\u{E000}private prefix \(customHome.path)2/private inside /Net\u{001B}work/Ho\u{00A0}mes/al\u{2003}ice/private"
    let output = EventLogger.sanitizeError(input, homeDirectory: customHome)

    XCTAssertTrue(output.contains("colon ~: permission"))
    XCTAssertTrue(output.contains("comma ~,"))
    XCTAssertTrue(output.contains("close (~)"))
    XCTAssertTrue(output.contains("nbsp ~ private"))
    XCTAssertTrue(output.contains("em ~ private"))
    XCTAssertTrue(output.contains("newline ~ private"))
    XCTAssertTrue(output.contains("tab ~ private"))
    XCTAssertTrue(output.contains("nul ~ private"))
    XCTAssertTrue(output.contains("private-use ~ private"))
    XCTAssertTrue(output.contains("prefix \(customHome.path)2/private"))
    XCTAssertTrue(output.contains("inside ~/private"))
  }

  func testCustomHomeBoundaryDistinguishesSentencePunctuationFromPathPrefixes() {
    let customHome = URL(fileURLWithPath: "/Network/Homes/alice")
    let input =
      "period \(customHome.path). next dash \(customHome.path)- next quote \"\(customHome.path)\" bang \(customHome.path)! question \(customHome.path)? hyphen-prefix \(customHome.path)-work underscore-prefix \(customHome.path)_test dot-prefix \(customHome.path).dev"
    let output = EventLogger.sanitizeError(input, homeDirectory: customHome)

    XCTAssertTrue(output.contains("period ~. next"))
    XCTAssertTrue(output.contains("dash ~- next"))
    XCTAssertTrue(output.contains("quote \"~\""))
    XCTAssertTrue(output.contains("bang ~!"))
    XCTAssertTrue(output.contains("question ~?"))
    XCTAssertTrue(output.contains("hyphen-prefix \(customHome.path)-work"))
    XCTAssertTrue(output.contains("underscore-prefix \(customHome.path)_test"))
    XCTAssertTrue(output.contains("dot-prefix \(customHome.path).dev"))
  }

  func testCustomHomeBoundaryHandlesUnicodeAndRemovedPunctuationRuns() {
    let customHome = URL(fileURLWithPath: "/Network/Homes/alice")
    let input =
      "smart \u{201C}\(customHome.path)\u{201D} em \(customHome.path)\u{2014}failed ellipsis \(customHome.path)\u{2026}Next dots \(customHome.path)... next cluster \(customHome.path)...\u{201D})Next nbsp \(customHome.path).\u{00A0}Next control \(customHome.path).\u{0000}Next ignorable \(customHome.path).\u{034F}Next"
    let output = EventLogger.sanitizeError(input, homeDirectory: customHome)

    XCTAssertTrue(output.contains("smart \u{201C}~\u{201D}"))
    XCTAssertTrue(output.contains("em ~\u{2014}failed"))
    XCTAssertTrue(output.contains("ellipsis ~\u{2026}Next"))
    XCTAssertTrue(output.contains("dots ~... next"))
    XCTAssertTrue(output.contains("cluster ~...\u{201D})Next"))
    XCTAssertTrue(output.contains("nbsp ~.Next"))
    XCTAssertTrue(output.contains("control ~.Next"))
    XCTAssertTrue(output.contains("ignorable ~.Next"))
  }

  func testCustomHomeBoundaryHandlesLocalizedPunctuation() {
    let customHome = URL(fileURLWithPath: "/Network/Homes/alice")
    let input =
      "fullwidth-colon \(customHome.path)\u{FF1A}Next fullwidth-comma \(customHome.path)\u{FF0C}Next ideographic-comma \(customHome.path)\u{3001}Next arabic-comma \(customHome.path)\u{060C}Next"
    let output = EventLogger.sanitizeError(input, homeDirectory: customHome)

    XCTAssertTrue(output.contains("fullwidth-colon ~\u{FF1A}Next"))
    XCTAssertTrue(output.contains("fullwidth-comma ~\u{FF0C}Next"))
    XCTAssertTrue(output.contains("ideographic-comma ~\u{3001}Next"))
    XCTAssertTrue(output.contains("arabic-comma ~\u{060C}Next"))
  }

  func testSanitizationRetainedScalarBoundFailsClosedForCombiningInput() {
    let input = "e" + String(repeating: "\u{0301}", count: 10_000)
    let output = EventLogger.sanitizeError(input)

    XCTAssertEqual(output, "<redacted>")
  }

  func testSanitizationFailsClosedForLongNonmatchingInput() {
    let input = String(repeating: "x", count: 1_000_000)
    let output = EventLogger.sanitizeError(input)

    XCTAssertEqual(output, "<redacted>")
  }

  func testSanitizationBoundCountsRetainedScalarsAfterRemovingObfuscators() {
    let customHome = URL(fileURLWithPath: "/Network/Homes/alice")
    let input = String(repeating: "\u{2060}", count: 4_078) + customHome.path

    XCTAssertEqual(EventLogger.sanitizeError(input, homeDirectory: customHome), "~")

    let retainedPrefix = String(repeating: " ", count: 4_078) + customHome.path
    XCTAssertEqual(
      EventLogger.sanitizeError(retainedPrefix, homeDirectory: customHome), "<redacted>")
  }

  func testSanitizationFailsClosedWhenObfuscatorsExceedRawScanBound() {
    let customHome = URL(fileURLWithPath: "/Network/Homes/alice")
    let input = String(repeating: "\u{2060}", count: 20_000) + customHome.path

    XCTAssertEqual(EventLogger.sanitizeError(input, homeDirectory: customHome), "<redacted>")
  }

  func testLoggerNormalizesControlCharactersBeforeRetainingOrLoggingErrors() {
    let input =
      "first\r\nsecond\ttab\u{001B}[31m red\u{0000}null\u{0007}bell\u{001F}unit\u{007F}delete\u{0085}next\u{2028}last /Users/alice/private token=log-secret"
    let output = EventLogger.sanitizeError(input)
    let unsafeCharacters = CharacterSet.controlCharacters.union(.newlines)

    XCTAssertFalse(output.unicodeScalars.contains { unsafeCharacters.contains($0) })
    XCTAssertFalse(output.contains("alice"))
    XCTAssertFalse(output.contains("log-secret"))
    XCTAssertTrue(output.contains("firstsecondtab[31m rednullbellunitdeletenextlast"))

    let logger = EventLogger()
    logger.error(input)
    XCTAssertEqual(logger.recentErrors, [output])
  }

  func testDiagnosticsExportBoundarySanitizesUntrustedHookAndTrustSummaries() {
    let hook = HookInstallationStatus(
      installedEvents: [],
      helperInstalled: false,
      configurationExists: true,
      error:
        "invalid config\r\nInjected: yes\t\u{001B}[31m /Users/alice/private token=hook-secret\u{0000}"
    )
    let trust = CodexHookTrustReport(
      state: .unavailable(
        "probe failed\u{0007}\nFake: trusted\u{0085}Authorization: Bearer trust-secret"),
      eventStatuses: [:]
    )
    let output = DiagnosticsService.formatFields([
      ("Hook status", hook.summary),
      ("Codex hook trust", trust.state.summary),
    ])
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    let unsafeCharacters = CharacterSet.controlCharacters.union(.newlines)

    XCTAssertEqual(lines.count, 2)
    XCTAssertFalse(
      lines.contains { line in
        line.unicodeScalars.contains { unsafeCharacters.contains($0) }
      })
    XCTAssertFalse(output.contains("alice"))
    XCTAssertFalse(output.contains("hook-secret"))
    XCTAssertFalse(output.contains("trust-secret"))
    XCTAssertTrue(output.contains("Hook status: invalid configInjected: yes[31m ~/private"), output)
    XCTAssertTrue(output.contains("Codex hook trust: probe failedFake: authorization=<redacted>"))
  }

  func testIntegrationPresentationTreatsReviewAsBlockedAndActionable() {
    let healthy = HookInstallationStatus(
      installedEvents: Set(HookInstaller.supportedEvents),
      helperInstalled: true,
      configurationExists: true,
      error: nil
    )
    XCTAssertEqual(
      CodexIntegrationPresentation.diagnosticStatus(
        hookStatus: healthy,
        trustState: .needsReview,
        bridgeIsListening: true
      ),
      "STATUS READY through local observation; APPROVAL ACTIONS BLOCKED until review in Codex /hooks"
    )

    let guidance = CodexIntegrationPresentation.guidance(for: .needsReview)
    XCTAssertTrue(guidance.contains("Codex CLI"), guidance)
    XCTAssertTrue(guidance.contains("enter /hooks"), guidance)
    XCTAssertTrue(guidance.contains("Local observation can show current activity"), guidance)
    XCTAssertTrue(guidance.contains("approval actions begin after Codex trusts"), guidance)
  }

  func testIntegrationPresentationNeverReportsUnknownTrustAsReady() {
    let healthy = HookInstallationStatus(
      installedEvents: Set(HookInstaller.supportedEvents),
      helperInstalled: true,
      configurationExists: true,
      error: nil
    )
    let unknownStates: [CodexHookTrustState] = [
      .notChecked,
      .needsReview,
      .incomplete,
      .unavailable("Codex unavailable"),
    ]

    for state in unknownStates {
      XCTAssertFalse(
        CodexIntegrationPresentation.diagnosticStatus(
          hookStatus: healthy,
          trustState: state,
          bridgeIsListening: true
        ).hasPrefix("READY"),
        "Unexpected ready state for \(state)"
      )
    }
    XCTAssertTrue(
      CodexIntegrationPresentation.diagnosticStatus(
        hookStatus: healthy,
        trustState: .trusted,
        bridgeIsListening: true
      ).hasPrefix("READY"))
  }

  func testIntegrationPresentationRequiresHealthyFilesAndBridgeBeforeReady() {
    let missing = HookInstallationStatus(
      installedEvents: [], helperInstalled: false, configurationExists: false, error: nil)
    let healthy = HookInstallationStatus(
      installedEvents: Set(HookInstaller.supportedEvents),
      helperInstalled: true,
      configurationExists: true,
      error: nil
    )

    XCTAssertFalse(
      CodexIntegrationPresentation.diagnosticStatus(
        hookStatus: missing,
        trustState: .trusted,
        bridgeIsListening: true
      ).hasPrefix("READY"))
    XCTAssertFalse(
      CodexIntegrationPresentation.diagnosticStatus(
        hookStatus: healthy,
        trustState: .trusted,
        bridgeIsListening: false
      ).hasPrefix("READY"))
  }

  func testUnavailableTrustGuidancePreservesReasonWithoutClaimingReviewFixesIt() {
    let guidance = CodexIntegrationPresentation.guidance(
      for: .unavailable("probe failed; authorization=secret"))

    XCTAssertTrue(guidance.contains("probe failed"), guidance)
    XCTAssertTrue(guidance.contains("authorization=<redacted>"), guidance)
    XCTAssertFalse(guidance.contains("/hooks"), guidance)
  }

  func testListeningSocketIsExplicitlyTransportOnly() {
    let status = DiagnosticsService.bridgeSocketStatus(isListening: true)

    XCTAssertTrue(status.contains("transport only"), status)
    XCTAssertTrue(status.contains("does not prove Codex hook execution"), status)
  }

  func testOnboardingDoesNotClaimReadyBeforeCodexTrust() {
    for state in [
      CodexHookTrustState.notChecked,
      .needsReview,
      .incomplete,
      .unavailable("Codex unavailable"),
    ] {
      XCTAssertFalse(OnboardingView.canContinueFromIntegration(trustState: state))
      XCTAssertEqual(
        OnboardingView.finishTitle(trustState: state), "Cowlick is ready in limited mode.")
      XCTAssertEqual(OnboardingView.completionButtonTitle(trustState: state), "Start Cowlick")
    }
    XCTAssertTrue(OnboardingView.canContinueFromIntegration(trustState: .trusted))
    XCTAssertEqual(OnboardingView.finishTitle(trustState: .trusted), "Cowlick is ready.")
    XCTAssertEqual(OnboardingView.completionButtonTitle(trustState: .trusted), "Start Cowlick")
  }

  func testReviewOnboardingExplainsOneActionHandoffAndApprovalBoundary() {
    let detail = OnboardingView.finishDetail(
      trustState: .needsReview,
      integrationDeferred: true
    )
    let instruction = OnboardingView.finishInstruction(trustState: .needsReview)

    XCTAssertTrue(detail.contains("Usage and local activity"), detail)
    XCTAssertTrue(detail.contains("Approval actions"), detail)
    XCTAssertFalse(detail.contains("fully connected"), detail)
    XCTAssertTrue(instruction.contains("Paste the copied command"), instruction)
    XCTAssertTrue(instruction.contains("approve Cowlick once"), instruction)
    XCTAssertTrue(instruction.contains("checks automatically"), instruction)
    XCTAssertTrue(instruction.contains("then return"), instruction)
  }

  func testDiagnosticsSanitizesEventScalarsBeforeAddingSeparators() {
    let record = SanitizedBridgeRecord(
      id: UUID(),
      timestamp: Date(timeIntervalSince1970: 0),
      event: "OPENAI_API_KEY",
      project: "=separate-field-value",
      outcome: "accepted\nInjected"
    )
    let output = DiagnosticsService.formatEvent(record)

    XCTAssertTrue(output.contains("OPENAI_API_KEY =separate-field-value acceptedInjected"))
    XCTAssertFalse(output.contains("<redacted>"))
    XCTAssertEqual(output.split(separator: "\n").count, 1)
  }

  func testKeepsOnlyTenSanitizedEvents() {
    let logger = EventLogger()
    for index in 0..<12 {
      logger.record(event: .working, project: "/Users/person/Project\(index)")
    }
    XCTAssertEqual(logger.recentEvents.count, 10)
    XCTAssertEqual(logger.recentEvents.last?.project, "Project11")
    XCTAssertFalse(logger.recentEvents.contains { $0.project.contains("/Users/") })
  }
}
