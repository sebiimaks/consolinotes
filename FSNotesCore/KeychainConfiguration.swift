/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See Licenses/native/Apple-GenericKeychain.txt and THIRD_PARTY_NOTICES.md
 for the original GenericKeychain sample's licensing information.
 
 Abstract:
 A simple struct that defines the service and access group to be used by the sample apps.
 */

import Foundation

struct KeychainConfiguration {
    static let serviceName = "consolinotes"

    /// The service name FSNotes uses. A master password saved under it is copied to `serviceName` when first read.
    static let legacyServiceName = "FSNotesApp"

    static let masterPasswordAccount = "Master Password"

    static func readMasterPassword() throws -> String {
        let item = KeychainPasswordItem(service: serviceName, account: masterPasswordAccount)

        do {
            return try item.readPassword()
        } catch {
            let legacy = KeychainPasswordItem(service: legacyServiceName, account: masterPasswordAccount)
            guard let password = try? legacy.readPassword() else { throw error }

            try? item.savePassword(password)
            return password
        }
    }

    /*
     Specifying an access group to use with `KeychainPasswordItem` instances
     will create items shared accross both apps.
     
     For information on App ID prefixes, see:
     https://developer.apple.com/library/ios/documentation/General/Conceptual/DevPedia-CocoaCore/AppID.html
     and:
     https://developer.apple.com/library/ios/technotes/tn2311/_index.html
     */
    //    static let accessGroup = "[YOUR APP ID PREFIX].com.example.apple-samplecode.GenericKeychainShared"

    /*
     Not specifying an access group to use with `KeychainPasswordItem` instances
     will create items specific to each app.
     */
    static let accessGroup: String? = nil
}
