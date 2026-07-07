import CryptoKit
import Foundation

public struct BedrockCredentials: Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken?.isEmpty == true ? nil : sessionToken
    }
}

/// Small Bedrock Runtime client for the Converse API. We avoid pulling in the
/// AWS SDK so the app can keep shipping as a single macOS bundle.
public struct BedrockRuntimeClient: Sendable {
    private let region: String
    private let credentials: BedrockCredentials
    private let transport: HTTPTransporting
    private let clock: @Sendable () -> Date

    public init(
        region: String,
        credentials: BedrockCredentials,
        transport: HTTPTransporting = HTTPTransport(),
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.region = region
        self.credentials = credentials
        self.transport = transport
        self.clock = clock
    }

    public func converse(
        modelID: String,
        systemPrompt: String,
        userText: String,
        maxTokens: Int,
        temperature: Double
    ) async throws -> String {
        let requestBody = ConverseRequest(
            system: [.init(text: systemPrompt)],
            messages: [.init(role: "user", content: [.init(text: userText)])],
            inferenceConfig: .init(maxTokens: maxTokens, temperature: temperature)
        )
        let body = try JSONEncoder.bedrock.encode(requestBody)
        let path = "/model/\(Self.uriEncode(modelID, encodeSlash: true))/converse"
        let host = "bedrock-runtime.\(region).amazonaws.com"
        guard let url = URL(string: "https://\(host)\(path)") else {
            throw BedrockError.malformedRequest("invalid Bedrock endpoint")
        }

        let signed = try SigV4Signer.sign(
            method: "POST",
            url: url,
            host: host,
            path: path,
            body: body,
            region: region,
            service: "bedrock",
            credentials: credentials,
            date: clock()
        )
        let response = try await transport.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: signed,
            body: body,
            timeout: 60
        ))
        guard (200..<300).contains(response.status) else {
            throw BedrockError.upstream(response.status, String(data: response.body, encoding: .utf8) ?? "")
        }
        let envelope = try JSONDecoder().decode(ConverseResponse.self, from: response.body)
        let text = envelope.output?.message.content.compactMap(\.text).joined(separator: "\n") ?? ""
        guard !text.isEmpty else { throw BedrockError.malformedResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uriEncode(_ value: String, encodeSlash: Bool) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        var output = ""
        for byte in value.utf8 {
            if unreserved.contains(byte) {
                output.unicodeScalars.append(UnicodeScalar(Int(byte))!)
            } else if byte == UInt8(ascii: "/"), !encodeSlash {
                output.append("/")
            } else {
                output += String(format: "%%%02X", byte)
            }
        }
        return output
    }

    private struct ConverseRequest: Encodable {
        let system: [ContentBlock]
        let messages: [Message]
        let inferenceConfig: InferenceConfig

        struct Message: Encodable {
            let role: String
            let content: [ContentBlock]
        }

        struct ContentBlock: Encodable {
            let text: String
        }

        struct InferenceConfig: Encodable {
            let maxTokens: Int
            let temperature: Double
        }
    }

    private struct ConverseResponse: Decodable {
        let output: Output?

        struct Output: Decodable {
            let message: Message
        }

        struct Message: Decodable {
            let content: [ContentBlock]
        }

        struct ContentBlock: Decodable {
            let text: String?
        }
    }
}

public enum BedrockError: Error, Equatable {
    case missingCredentials
    case missingRegion
    case missingModel
    case malformedRequest(String)
    case malformedResponse
    case upstream(Int, String)
}

private enum SigV4Signer {
    static func sign(
        method: String,
        url: URL,
        host: String,
        path: String,
        body: Data,
        region: String,
        service: String,
        credentials: BedrockCredentials,
        date: Date
    ) throws -> [String: String] {
        let amzDate = timestampFormatter.string(from: date)
        let dateStamp = datestampFormatter.string(from: date)
        let payloadHash = sha256Hex(body)

        var headers: [(String, String)] = [
            ("content-type", "application/json"),
            ("host", host),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate),
        ]
        if let token = credentials.sessionToken {
            headers.append(("x-amz-security-token", token))
        }
        headers.sort { $0.0 < $1.0 }

        let canonicalHeaders = headers
            .map { "\($0.0):\(normalizeHeaderValue($0.1))\n" }
            .joined()
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalRequest = [
            method,
            path.isEmpty ? "/" : path,
            url.query ?? "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let credentialScope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = deriveSigningKey(secret: credentials.secretAccessKey, date: dateStamp, region: region, service: service)
        let signature = hmacHex(key: signingKey, data: Data(stringToSign.utf8))
        let authorization = "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var output: [String: String] = [
            "Content-Type": "application/json",
            "Host": host,
            "X-Amz-Content-Sha256": payloadHash,
            "X-Amz-Date": amzDate,
            "Authorization": authorization,
        ]
        if let token = credentials.sessionToken {
            output["X-Amz-Security-Token"] = token
        }
        return output
    }

    private static func deriveSigningKey(secret: String, date: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), data: Data(date.utf8))
        let kRegion = hmac(key: kDate, data: Data(region.utf8))
        let kService = hmac(key: kRegion, data: Data(service.utf8))
        return hmac(key: kService, data: Data("aws4_request".utf8))
    }

    private static func hmac(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    private static func hmacHex(key: Data, data: Data) -> String {
        hmac(key: key, data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeHeaderValue(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    nonisolated(unsafe) private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    nonisolated(unsafe) private static let datestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

private extension JSONEncoder {
    static let bedrock: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
