//
//  main.swift
//  Extension
//
//  Created by Halle Winkler on 10.08.22.
//

import Foundation
import CoreMediaIO
import Darwin
import os.log

private let logger = Logger(subsystem: "com.garethpaul.GarethVideoCam",
                            category: "ExtensionMain")

do {
    let providerSource = try ExtensionProviderSource(clientQueue: nil)
    CMIOExtensionProvider.startService(provider: providerSource.provider)
    CFRunLoopRun()
} catch {
    logger.error("Failed to start camera extension service: \(error.localizedDescription, privacy: .public)")
    exit(EXIT_FAILURE)
}
