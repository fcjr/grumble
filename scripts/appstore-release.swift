// Drives App Store Connect after an upload: ensures the store version for
// APP_VERSION exists, waits for build APP_BUILD to finish processing,
// attaches it, sets "What's New" from RELEASE_NOTES and the support URL,
// and with --submit submits the version for review. Idempotent: safe to
// re-run.
//
// Env: ASC_KEY_FILE (path to .p8), ASC_KEY_ID, ASC_ISSUER_ID,
//      APP_VERSION, APP_BUILD, RELEASE_NOTES (optional),
//      SUPPORT_URL (optional)

import CryptoKit
import Foundation

let appID = "6791293617"  // Grumble in App Store Connect
let apiBase = "https://api.appstoreconnect.apple.com"

func env(_ name: String) -> String? {
    let v = ProcessInfo.processInfo.environment[name]
    return v?.isEmpty == false ? v : nil
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard let keyFile = env("ASC_KEY_FILE"), let keyID = env("ASC_KEY_ID"),
    let issuerID = env("ASC_ISSUER_ID"),
    let version = env("APP_VERSION"), let buildNumber = env("APP_BUILD")
else {
    fail("ASC_KEY_FILE, ASC_KEY_ID, ASC_ISSUER_ID, APP_VERSION and APP_BUILD are required")
}
let releaseNotes = env("RELEASE_NOTES") ?? "Bug fixes and improvements."
// App Review requires a support page with real help on it, not the marketing
// home page (guideline 1.5).
let supportURL = env("SUPPORT_URL") ?? "https://grumble.computer/support"
let shouldSubmit = CommandLine.arguments.contains("--submit")

// MARK: - JWT

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func makeToken() -> String {
    guard let pem = try? String(contentsOfFile: keyFile, encoding: .utf8),
        let key = try? P256.Signing.PrivateKey(pemRepresentation: pem)
    else { fail("cannot read P256 key from \(keyFile)") }
    let now = Int(Date().timeIntervalSince1970)
    let header = try! JSONSerialization.data(withJSONObject: [
        "alg": "ES256", "kid": keyID, "typ": "JWT",
    ])
    let payload = try! JSONSerialization.data(withJSONObject: [
        "iss": issuerID, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1",
    ] as [String: Any])
    let signingInput = "\(base64url(header)).\(base64url(payload))"
    let signature = try! key.signature(for: Data(signingInput.utf8))
    return "\(signingInput).\(base64url(signature.rawRepresentation))"
}

// MARK: - HTTP

func api(
    _ method: String, _ path: String, body: [String: Any]? = nil,
    allowedErrors: [Int] = []
) -> [String: Any] {
    var request = URLRequest(url: URL(string: path.hasPrefix("http") ? path : apiBase + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(makeToken())", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try! JSONSerialization.data(withJSONObject: body)
    }
    var result: [String: Any] = [:]
    var status = 0
    let done = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { fail("\(method) \(path): \(error.localizedDescription)") }
        status = (response as! HTTPURLResponse).statusCode
        if let data, !data.isEmpty,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            result = json
        }
        done.signal()
    }.resume()
    done.wait()
    if status >= 400 && !allowedErrors.contains(status) {
        fail("\(method) \(path) -> \(status): \(result)")
    }
    result["_status"] = status
    return result
}

func items(_ response: [String: Any]) -> [[String: Any]] {
    response["data"] as? [[String: Any]] ?? []
}

// MARK: - Steps

func ensureVersion() -> String {
    let existing = items(
        api(
            "GET",
            "/v1/apps/\(appID)/appStoreVersions?filter[platform]=MAC_OS&filter[versionString]=\(version)&limit=1"
        ))
    if let id = existing.first?["id"] as? String {
        print("version \(version) exists (\(id))")
        return id
    }
    let created = api(
        "POST", "/v1/appStoreVersions",
        body: [
            "data": [
                "type": "appStoreVersions",
                "attributes": [
                    "platform": "MAC_OS", "versionString": version,
                    "releaseType": "AFTER_APPROVAL",
                ],
                "relationships": ["app": ["data": ["type": "apps", "id": appID]]],
            ]
        ], allowedErrors: [409, 422])
    if let data = created["data"] as? [String: Any], let id = data["id"] as? String {
        print("created version \(version) (\(id))")
        return id
    }
    // Only one editable version can exist per platform. If a previous
    // version was never submitted (or was rejected), rename it in place
    // instead of creating a new one.
    let editableStates = [
        "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
        "METADATA_REJECTED", "INVALID_BINARY",
    ].joined(separator: ",")
    let editable = items(
        api(
            "GET",
            "/v1/apps/\(appID)/appStoreVersions?filter[platform]=MAC_OS&filter[appStoreState]=\(editableStates)&limit=1"
        ))
    guard let stale = editable.first, let id = stale["id"] as? String else {
        fail("cannot create version \(version) and no editable version to rename: \(created)")
    }
    let old =
        (stale["attributes"] as? [String: Any])?["versionString"] as? String ?? "unknown"
    _ = api(
        "PATCH", "/v1/appStoreVersions/\(id)",
        body: [
            "data": [
                "type": "appStoreVersions", "id": id,
                "attributes": ["versionString": version],
            ]
        ])
    print("renamed unsubmitted version \(old) -> \(version) (\(id))")
    return id
}

func waitForBuild() -> String {
    let deadline = Date().addingTimeInterval(45 * 60)
    while true {
        let response = items(
            api(
                "GET",
                "/v1/builds?filter[app]=\(appID)&filter[version]=\(buildNumber)&sort=-uploadedDate&limit=1"
            ))
        if let build = response.first, let id = build["id"] as? String,
            let attrs = build["attributes"] as? [String: Any],
            let state = attrs["processingState"] as? String
        {
            switch state {
            case "VALID":
                print("build \(buildNumber) processed (\(id))")
                return id
            case "FAILED", "INVALID":
                fail("build \(buildNumber) processing ended in \(state)")
            default:
                print("build \(buildNumber): \(state), waiting...")
            }
        } else {
            print("build \(buildNumber) not visible yet, waiting...")
        }
        if Date() > deadline { fail("timed out waiting for build \(buildNumber)") }
        Thread.sleep(forTimeInterval: 60)
    }
}

func attach(buildID: String, to versionID: String) {
    _ = api(
        "PATCH", "/v1/appStoreVersions/\(versionID)/relationships/build",
        body: ["data": ["type": "builds", "id": buildID]])
    print("attached build \(buildNumber) to \(version)")
}

func setLocalizations(versionID: String) {
    for loc in items(api("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations"))
    {
        guard let locID = loc["id"] as? String else { continue }
        // The support URL is patched on its own: the app's very first store
        // version has no What's New field, and the API rejects that whole
        // write, which would take the support URL down with it.
        let supportResponse = api(
            "PATCH", "/v1/appStoreVersionLocalizations/\(locID)",
            body: [
                "data": [
                    "type": "appStoreVersionLocalizations", "id": locID,
                    "attributes": ["supportUrl": supportURL],
                ]
            ], allowedErrors: [409, 422])
        let supportStatus = supportResponse["_status"] as! Int
        print(
            supportStatus < 400
                ? "set support URL to \(supportURL) (\(locID))"
                : "support URL not writable, version is locked (\(locID))")

        let response = api(
            "PATCH", "/v1/appStoreVersionLocalizations/\(locID)",
            body: [
                "data": [
                    "type": "appStoreVersionLocalizations", "id": locID,
                    "attributes": ["whatsNew": releaseNotes],
                ]
            ], allowedErrors: [409, 422])
        let status = response["_status"] as! Int
        print(status < 400 ? "set What's New (\(locID))" : "What's New not writable (initial version?)")
    }
}

func submissionItems(_ submissionID: String) -> [String] {
    items(api("GET", "/v1/reviewSubmissions/\(submissionID)/items?include=appStoreVersion"))
        .compactMap {
            let relationships = $0["relationships"] as? [String: Any]
            let version = relationships?["appStoreVersion"] as? [String: Any]
            return (version?["data"] as? [String: Any])?["id"] as? String
        }
}

func send(_ submissionID: String) {
    let response = api(
        "PATCH", "/v1/reviewSubmissions/\(submissionID)",
        body: [
            "data": [
                "type": "reviewSubmissions", "id": submissionID,
                "attributes": ["submitted": true],
            ]
        ], allowedErrors: [409])
    let status = response["_status"] as! Int
    print(
        status < 400
            ? "submitted \(version) for review"
            : "submission \(submissionID) was already sent")
}

func submit(versionID: String) {
    // Submissions that still hold onto their versions. A version can belong to
    // only one of them, and renaming a version keeps that association, so a
    // half-finished earlier run leaves the version parked in an old submission.
    let openStates = "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES"
    let open = items(
        api(
            "GET",
            "/v1/reviewSubmissions?filter[app]=\(appID)&filter[state]=\(openStates)&limit=50"
        ))

    for submission in open {
        guard let id = submission["id"] as? String,
            submissionItems(id).contains(versionID)
        else { continue }
        let state = (submission["attributes"] as? [String: Any])?["state"] as? String ?? "unknown"
        switch state {
        case "READY_FOR_REVIEW":
            print("version \(version) already in submission \(id), sending it")
            send(id)
        case "UNRESOLVED_ISSUES":
            // App Review rejected this version and still holds it. Nothing can
            // be resubmitted until the submission is answered or canceled, so
            // don't let the release job report success.
            fail("version \(version) is held by rejected submission \(id) - resolve it in App Store Connect")
        default:
            print("version \(version) already submitted in \(id) (\(state))")
        }
        return
    }

    var submissionID = open.first {
        ($0["attributes"] as? [String: Any])?["state"] as? String == "READY_FOR_REVIEW"
    }?["id"] as? String
    if submissionID == nil {
        let created = api(
            "POST", "/v1/reviewSubmissions",
            body: [
                "data": [
                    "type": "reviewSubmissions",
                    "attributes": ["platform": "MAC_OS"],
                    "relationships": ["app": ["data": ["type": "apps", "id": appID]]],
                ]
            ], allowedErrors: [409])
        submissionID = (created["data"] as? [String: Any])?["id"] as? String
        guard submissionID != nil else { fail("no usable review submission: \(created)") }
    }
    let id = submissionID!

    // A swallowed error here would leave a submission without our version,
    // so real failures must stay fatal.
    _ = api(
        "POST", "/v1/reviewSubmissionItems",
        body: [
            "data": [
                "type": "reviewSubmissionItems",
                "relationships": [
                    "reviewSubmission": [
                        "data": ["type": "reviewSubmissions", "id": id]
                    ],
                    "appStoreVersion": [
                        "data": ["type": "appStoreVersions", "id": versionID]
                    ],
                ],
            ]
        ])
    send(id)
}

// MARK: - Main

let versionID = ensureVersion()
let buildID = waitForBuild()
attach(buildID: buildID, to: versionID)
setLocalizations(versionID: versionID)
if shouldSubmit {
    submit(versionID: versionID)
} else {
    print("skipping review submission (pass --submit to enable)")
}
