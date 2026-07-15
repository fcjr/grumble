// Drives App Store Connect after an upload: ensures the store version for
// APP_VERSION exists, waits for build APP_BUILD to finish processing,
// attaches it, sets "What's New" from RELEASE_NOTES, and with --submit
// submits the version for review. Idempotent: safe to re-run.
//
// Env: ASC_KEY_FILE (path to .p8), ASC_KEY_ID, ASC_ISSUER_ID,
//      APP_VERSION, APP_BUILD, RELEASE_NOTES (optional)

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
        ])
    guard let data = created["data"] as? [String: Any], let id = data["id"] as? String else {
        fail("could not create version \(version): \(created)")
    }
    print("created version \(version) (\(id))")
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

func setReleaseNotes(versionID: String) {
    for loc in items(api("GET", "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations"))
    {
        guard let locID = loc["id"] as? String else { continue }
        // The app's very first store version has no What's New field; the
        // API rejects the write, which is fine to ignore.
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

func submit(versionID: String) {
    var submissionID: String?
    let created = api(
        "POST", "/v1/reviewSubmissions",
        body: [
            "data": [
                "type": "reviewSubmissions",
                "attributes": ["platform": "MAC_OS"],
                "relationships": ["app": ["data": ["type": "apps", "id": appID]]],
            ]
        ], allowedErrors: [409])
    if let data = created["data"] as? [String: Any] {
        submissionID = data["id"] as? String
    } else {
        // An open submission already exists - reuse it if it hasn't been sent.
        let open = items(
            api(
                "GET",
                "/v1/reviewSubmissions?filter[app]=\(appID)&filter[state]=READY_FOR_REVIEW&limit=1"
            ))
        submissionID = open.first?["id"] as? String
    }
    guard let submissionID else { fail("no usable review submission: \(created)") }

    _ = api(
        "POST", "/v1/reviewSubmissionItems",
        body: [
            "data": [
                "type": "reviewSubmissionItems",
                "relationships": [
                    "reviewSubmission": [
                        "data": ["type": "reviewSubmissions", "id": submissionID]
                    ],
                    "appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionID]],
                ],
            ]
        ], allowedErrors: [409])

    _ = api(
        "PATCH", "/v1/reviewSubmissions/\(submissionID)",
        body: [
            "data": [
                "type": "reviewSubmissions", "id": submissionID,
                "attributes": ["submitted": true],
            ]
        ])
    print("submitted \(version) for review")
}

// MARK: - Main

let versionID = ensureVersion()
let buildID = waitForBuild()
attach(buildID: buildID, to: versionID)
setReleaseNotes(versionID: versionID)
if shouldSubmit {
    submit(versionID: versionID)
} else {
    print("skipping review submission (pass --submit to enable)")
}
