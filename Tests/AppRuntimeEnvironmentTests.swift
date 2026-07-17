import XCTest
@testable import Dump

final class AppRuntimeEnvironmentTests: XCTestCase {
    func testHostedTestProcessIsRecognized() {
        XCTAssertTrue(AppRuntimeEnvironment.isUnitTestProcess())
    }

    func testRecognizesConfiguredUnitTestEnvironment() {
        XCTAssertTrue(AppRuntimeEnvironment.isUnitTestProcess(environment: [
            AppRuntimeEnvironment.unitTestingKey: "1",
        ]))
    }

    func testRecognizesXCTestHostMetadata() {
        XCTAssertTrue(AppRuntimeEnvironment.isUnitTestProcess(environment: [
            "XCTestConfigurationFilePath": "/tmp/DumpTests.xctestconfiguration",
        ]))
        XCTAssertTrue(AppRuntimeEnvironment.isUnitTestProcess(environment: [
            "XCTestBundlePath": "/tmp/DumpTests.xctest",
        ]))
    }

    func testNormalAppEnvironmentStartsServices() {
        XCTAssertFalse(AppRuntimeEnvironment.isUnitTestProcess(environment: [:]))
        XCTAssertFalse(AppRuntimeEnvironment.isUnitTestProcess(environment: [
            AppRuntimeEnvironment.unitTestingKey: "0",
        ]))
    }
}
