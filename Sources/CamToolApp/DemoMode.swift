#if DEBUG
import AppKit
import CamToolKit

/// Debug builds only: fills the app with fictitious devices for README screenshots.
///
///     CAMTOOL_DEMO=1 CAMTOOL_SNAPSHOT=/path/shot.png CAMTOOL_LANG=en .build/debug/CamToolApp
///
/// All values below are made up; nothing comes from a real network.
enum DemoMode {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["CAMTOOL_DEMO"] == "1" }
    static var snapshotPath: String? { ProcessInfo.processInfo.environment["CAMTOOL_SNAPSHOT"] }

    static func device(ip: String, mac: String, model: String, serial: String, version: String,
                       mask: String = "255.255.255.0", gateway: String = "192.168.1.1", initialized: Bool = true) -> Device {
        Device(info: [
            "DeviceType": .string(model), "SerialNo": .string(serial), "Version": .string(version),
            "HttpPort": 80, "Port": 37777, "Init": .int(initialized ? 2 : 1),
            "IPv4Address": ["IPAddress": .string(ip), "SubnetMask": .string(mask),
                            "DefaultGateway": .string(gateway), "DhcpEnable": false],
        ], source: ip, mac: mac)
    }

    static let devices: [Device] = [
        device(ip: "192.168.1.108", mac: "02:00:5e:10:00:01", model: "IPC-HDW2441T-S", serial: "DEMO0000000001",
               version: "2.800.0000000.40.R", initialized: false),
        device(ip: "192.168.1.120", mac: "02:00:5e:10:00:02", model: "IPC-HFW3849T1-AS-PV", serial: "DEMO0000000002",
               version: "3.140.0000000.30.R"),
        device(ip: "192.168.1.121", mac: "02:00:5e:10:00:03", model: "IPC-HDW3849H-AS-PV", serial: "DEMO0000000003",
               version: "3.140.0000000.30.R"),
        device(ip: "192.168.1.122", mac: "02:00:5e:10:00:04", model: "IPC-HDBW5449R-ASE", serial: "DEMO0000000004",
               version: "2.840.0000000.20.R"),
        device(ip: "10.1.1.109", mac: "02:00:5e:10:00:05", model: "NVR4216-16P-4KS3", serial: "DEMO0000000005",
               version: "4.003.0000000.1.R", gateway: "10.1.1.1"),
    ]

    static let selectedDetails = DeviceDetails(
        info: [
            "deviceType": "IPC-HFW3849T1-AS-PV", "serialNumber": "DEMO0000000002", "Version": "3.140.0000000.30.R",
            "BuildDate": "2026-06-15", "updateSerial": "IPC-HFW3849T1-AS-PV", "WebVersion": "5.001.0",
            "hardwareVersion": "1.00", "processor": "SSC379G", "SecurityBaseLineVersion": "V2.4",
        ],
        network: [
            "DefaultInterface": "eth0", "Hostname": "CAM-ENTRANCE",
            "eth0": [
                "IPAddress": "192.168.1.120", "SubnetMask": "255.255.255.0", "DefaultGateway": "192.168.1.1",
                "DnsServers": ["192.168.1.1", "1.1.1.1"], "DhcpEnable": false, "MTU": 1500,
                "PhysicalAddress": "02:00:5e:10:00:02",
            ],
        ]
    )

    /// Saves the main window's content as a PNG, then quits.
    @MainActor static func snapshot(to path: String) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.center()
        try? await Task.sleep(for: .seconds(1))
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        NSApp.terminate(nil)
    }
}

#endif
