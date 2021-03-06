//
//  CloudKitAccountZone.swift
//  Account
//
//  Created by Maurice Parker on 3/21/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import os.log
import RSWeb
import CloudKit

final class CloudKitAccountZone: CloudKitZone {

	typealias ContainerWebFeed = (webFeedExternalID: String, containerWebFeedExternalID: String, containerExternalID: String)
	
	static var zoneID: CKRecordZone.ID {
		return CKRecordZone.ID(zoneName: "Account", ownerName: CKCurrentUserDefaultName)
	}
	
	var log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "CloudKit")

    weak var container: CKContainer?
    weak var database: CKDatabase?
	weak var refreshProgress: DownloadProgress?
	var delegate: CloudKitZoneDelegate? = nil
    
	struct CloudKitWebFeed {
		static let recordType = "WebFeed"
		struct Fields {
			static let url = "url"
			static let editedName = "editedName"
			static let containerExternalIDs = "folderExternalIDs"
		}
	}
	
	struct CloudKitContainer {
		static let recordType = "Container"
		struct Fields {
			static let isAccount = "isAccount"
			static let name = "name"
		}
	}
	
	init(container: CKContainer) {
        self.container = container
        self.database = container.privateCloudDatabase
    }
    
	///  Persist a web feed record to iCloud and return the external key
	func createWebFeed(url: String, editedName: String?, container: Container, completion: @escaping (Result<String, Error>) -> Void) {
		let record = CKRecord(recordType: CloudKitWebFeed.recordType, recordID: generateRecordID())
		record[CloudKitWebFeed.Fields.url] = url
		if let editedName = editedName {
			record[CloudKitWebFeed.Fields.editedName] = editedName
		}
		
		guard let containerExternalID = container.externalID else {
			completion(.failure(CloudKitZoneError.invalidParameter))
			return
		}
		record[CloudKitWebFeed.Fields.containerExternalIDs] = [containerExternalID]

		save(record) { result in
			switch result {
			case .success:
				completion(.success(record.externalID))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	/// Rename the given web feed
	func renameWebFeed(_ webFeed: WebFeed, editedName: String?, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let externalID = webFeed.externalID else {
			completion(.failure(CloudKitZoneError.invalidParameter))
			return
		}

		let recordID = CKRecord.ID(recordName: externalID, zoneID: Self.zoneID)
		let record = CKRecord(recordType: CloudKitWebFeed.recordType, recordID: recordID)
		record[CloudKitWebFeed.Fields.editedName] = editedName
		
		save(record) { result in
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	/// Deletes a web feed from iCloud
	func removeWebFeed(_ webFeed: WebFeed, from: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let fromContainerExternalID = from.externalID else {
			completion(.failure(CloudKitZoneError.invalidParameter))
			return
		}
		
		fetch(externalID: webFeed.externalID) { result in
			switch result {
			case .success(let record):
				if let containerExternalIDs = record[CloudKitWebFeed.Fields.containerExternalIDs] as? [String] {
					var containerExternalIDSet = Set(containerExternalIDs)
					containerExternalIDSet.remove(fromContainerExternalID)
					if containerExternalIDSet.isEmpty {
						self.delete(externalID: webFeed.externalID , completion: completion)
					} else {
						record[CloudKitWebFeed.Fields.containerExternalIDs] = Array(containerExternalIDSet)
						self.save(record, completion: completion)
					}
				}
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func moveWebFeed(_ webFeed: WebFeed, from: Container, to: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let fromContainerExternalID = from.externalID, let toContainerExternalID = to.externalID else {
			completion(.failure(CloudKitZoneError.invalidParameter))
			return
		}
		
		fetch(externalID: webFeed.externalID) { result in
			switch result {
			case .success(let record):
				if let containerExternalIDs = record[CloudKitWebFeed.Fields.containerExternalIDs] as? [String] {
					var containerExternalIDSet = Set(containerExternalIDs)
					containerExternalIDSet.remove(fromContainerExternalID)
					containerExternalIDSet.insert(toContainerExternalID)
					record[CloudKitWebFeed.Fields.containerExternalIDs] = Array(containerExternalIDSet)
					self.save(record, completion: completion)
				}
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func addWebFeed(_ webFeed: WebFeed, to: Container, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let toContainerExternalID = to.externalID else {
			completion(.failure(CloudKitZoneError.invalidParameter))
			return
		}
		
		fetch(externalID: webFeed.externalID) { result in
			switch result {
			case .success(let record):
				if let containerExternalIDs = record[CloudKitWebFeed.Fields.containerExternalIDs] as? [String] {
					var containerExternalIDSet = Set(containerExternalIDs)
					containerExternalIDSet.insert(toContainerExternalID)
					record[CloudKitWebFeed.Fields.containerExternalIDs] = Array(containerExternalIDSet)
					self.save(record, completion: completion)
				}
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func findOrCreateAccount(completion: @escaping (Result<String, Error>) -> Void) {
		let predicate = NSPredicate(format: "isAccount = \"true\"")
		let ckQuery = CKQuery(recordType: CloudKitContainer.recordType, predicate: predicate)
		
		query(ckQuery) { result in
			switch result {
			case .success(let records):
				completion(.success(records[0].externalID))
			case .failure:
				self.createContainer(name: "Account", isAccount: true, completion: completion)
			}
		}
	}
	
	func createFolder(name: String, completion: @escaping (Result<String, Error>) -> Void) {
		createContainer(name: name, isAccount: false, completion: completion)
	}
	
	func renameFolder(_ folder: Folder, to name: String, completion: @escaping (Result<Void, Error>) -> Void) {
		guard let externalID = folder.externalID else {
			completion(.failure(CloudKitZoneError.invalidParameter))
			return
		}

		let recordID = CKRecord.ID(recordName: externalID, zoneID: Self.zoneID)
		let record = CKRecord(recordType: CloudKitContainer.recordType, recordID: recordID)
		record[CloudKitContainer.Fields.name] = name
		
		save(record) { result in
			switch result {
			case .success:
				completion(.success(()))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
	func removeFolder(_ folder: Folder, completion: @escaping (Result<Void, Error>) -> Void) {
		delete(externalID: folder.externalID, completion: completion)
	}
	
}

private extension CloudKitAccountZone {
	
	func createContainer(name: String, isAccount: Bool, completion: @escaping (Result<String, Error>) -> Void) {
		let record = CKRecord(recordType: CloudKitContainer.recordType, recordID: generateRecordID())
		record[CloudKitContainer.Fields.name] = name
		record[CloudKitContainer.Fields.isAccount] = isAccount ? "true" : "false"

		save(record) { result in
			switch result {
			case .success:
				completion(.success(record.externalID))
			case .failure(let error):
				completion(.failure(error))
			}
		}
	}
	
}
