import Foundation

extension DockerService {
    // MARK: - JSON Parsing (socket API)

    static func parseContainersJSON(_ data: Data?) -> [Container] {
        guard let data = data else { return [] }
        guard
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [[String: Any]]
        else { return [] }
        return json.compactMap { obj in
            guard let id = obj["Id"] as? String,
                let names = obj["Names"] as? [String],
                let image = obj["Image"] as? String,
                let status = obj["Status"] as? String,
                let stateStr = obj["State"] as? String
            else { return nil }

            let name =
                names.first?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")) ?? id
            let state =
                Container.ContainerState(rawValue: stateStr.lowercased())
                ?? .unknown
            let ports = formatPorts(obj["Ports"])
            let createdAt: Date?
            if let createdEpoch = obj["Created"] as? TimeInterval {
                createdAt = Date(timeIntervalSince1970: createdEpoch)
            } else {
                createdAt = nil
            }

            let labels = obj["Labels"] as? [String: String] ?? [:]
            return Container(
                id: String(id.prefix(12)),
                name: name,
                image: image,
                status: status,
                state: state,
                ports: ports,
                createdAt: createdAt,
                composeProject: labels[ComposeGrouping.projectLabel].flatMap { $0.isEmpty ? nil : $0 },
                composeService: labels[ComposeGrouping.serviceLabel],
                composeWorkingDir: labels[ComposeGrouping.workingDirLabel],
                composeConfigFiles: labels[ComposeGrouping.configFilesLabel].map {
                    $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                } ?? []
            )
        }
    }

    static func parseImagesJSON(_ data: Data?) -> [DockerImage] {
        guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return json.compactMap { obj in
            guard let id = obj["Id"] as? String else { return nil }
            let shortID = id.hasPrefix("sha256:") ? String(id.dropFirst(7).prefix(12)) : String(id.prefix(12))
            let tags = obj["RepoTags"] as? [String] ?? []
            let repoTag = tags.first(where: { !$0.contains("<none>") }) ?? tags.first ?? "<none>"
            let size = obj["Size"] as? Int64 ?? 0
            let createdAt: Date?
            if let epoch = obj["Created"] as? TimeInterval {
                createdAt = Date(timeIntervalSince1970: epoch)
            } else {
                createdAt = nil
            }
            return DockerImage(id: shortID, repoTag: repoTag, size: size, createdAt: createdAt)
        }
    }

    static func parseNetworksJSON(_ data: Data?) -> [DockerNetwork] {
        guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return json.compactMap { obj in
            guard let id = obj["Id"] as? String,
                let name = obj["Name"] as? String
            else { return nil }
            let driver = obj["Driver"] as? String ?? ""
            let scope = obj["Scope"] as? String ?? ""
            return DockerNetwork(
                id: String(id.prefix(12)), name: name, driver: driver, scope: scope)
        }
        .filter { !["bridge", "host", "none"].contains($0.name) }
    }

    static func parseVolumesJSON(_ data: Data?) -> [DockerVolume] {
        guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let volumes = json["Volumes"] as? [[String: Any]]
        else { return [] }
        return volumes.compactMap { obj in
            guard let name = obj["Name"] as? String else { return nil }
            let driver = obj["Driver"] as? String ?? ""
            let mountpoint = obj["Mountpoint"] as? String ?? ""
            return DockerVolume(name: name, driver: driver, mountpoint: mountpoint)
        }
    }

    /// Format the Ports array from the Docker API into a display string.
    private static func formatPorts(_ portsObj: Any?) -> String {
        guard let portsArray = portsObj as? [[String: Any]] else {
            return ""
        }
        var parts: [String] = []
        for port in portsArray {
            let privatePort = port["PrivatePort"] as? Int ?? 0
            let portType = port["Type"] as? String ?? "tcp"
            if let publicPort = port["PublicPort"] as? Int,
                publicPort > 0
            {
                let ip = port["IP"] as? String ?? ""
                if ip == "::" { continue }  // Skip IPv6 duplicates
                if ip.isEmpty || ip == "0.0.0.0" {
                    parts.append(
                        "\(publicPort)->\(privatePort)/\(portType)")
                } else {
                    parts.append(
                        "\(ip):\(publicPort)->\(privatePort)/\(portType)"
                    )
                }
            } else {
                parts.append("\(privatePort)/\(portType)")
            }
        }
        return parts.joined(separator: ", ")
    }
}
